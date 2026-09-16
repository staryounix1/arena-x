-- Match room setup, two-player room confirmation, and timed match lifecycle.

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS room_setup_deadline_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS room_ready_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS match_deadline_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS room_creator_copied_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS room_opponent_copied_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_matches_lifecycle
  ON public.matches(status, room_setup_deadline_at, match_deadline_at);

CREATE OR REPLACE FUNCTION public.start_match_room_setup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'PLAYING' AND OLD.status = 'OPEN' THEN
    NEW.room_setup_deadline_at := COALESCE(NEW.room_setup_deadline_at, NOW() + INTERVAL '1 minute');
    NEW.room_ready_at := NULL;
    NEW.match_deadline_at := NULL;
    NEW.room_creator_copied_at := NULL;
    NEW.room_opponent_copied_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS start_match_room_setup ON public.matches;
CREATE TRIGGER start_match_room_setup
BEFORE UPDATE OF status ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.start_match_room_setup();

CREATE OR REPLACE FUNCTION public.set_match_room(match_id_value UUID, room_code_value TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  IF NULLIF(TRIM(room_code_value), '') IS NULL THEN RAISE EXCEPTION 'room code required'; END IF;
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  IF game.id IS NULL OR game.status <> 'PLAYING' OR game.opponent_id IS NULL THEN RAISE EXCEPTION 'match room is not available'; END IF;
  UPDATE public.matches
  SET room_code = LEFT(TRIM(room_code_value), 50),
      room_ready_at = COALESCE(room_ready_at, NOW()),
      updated_at = NOW()
  WHERE id = match_id_value;
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload)
  VALUES (match_id_value, auth.uid(), 'ROOM_READY', jsonb_build_object('room_code', LEFT(TRIM(room_code_value), 50)));
  PERFORM public.create_notification(game.creator_id, 'MATCH', 'غرفة المباراة جاهزة', 'أدخل إلى المباراة وانسخ أيدي الغرفة. يبدأ عداد اللعب بعد تأكيد اللاعب الثاني.', '/matches/' || game.id, 'match:room-ready:' || game.id);
  PERFORM public.create_notification(game.opponent_id, 'MATCH', 'غرفة المباراة جاهزة', 'أدخل إلى المباراة وانسخ أيدي الغرفة. يبدأ عداد اللعب بعد تأكيد اللاعب الثاني.', '/matches/' || game.id, 'match:room-ready:' || game.id || ':opponent');
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_match_room_copy(match_id_value UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  IF game.id IS NULL OR game.status <> 'PLAYING' OR game.room_code IS NULL OR auth.uid() NOT IN (game.creator_id, game.opponent_id) THEN
    RAISE EXCEPTION 'room copy is not available';
  END IF;
  IF auth.uid() = game.creator_id THEN
    UPDATE public.matches SET room_creator_copied_at = COALESCE(room_creator_copied_at, NOW()), updated_at = NOW() WHERE id = game.id;
  ELSE
    UPDATE public.matches SET room_opponent_copied_at = COALESCE(room_opponent_copied_at, NOW()), updated_at = NOW() WHERE id = game.id;
  END IF;
  UPDATE public.matches
  SET match_deadline_at = COALESCE(match_deadline_at, NOW() + INTERVAL '20 minutes'),
      updated_at = NOW()
  WHERE id = game.id
    AND room_creator_copied_at IS NOT NULL
    AND room_opponent_copied_at IS NOT NULL;
  IF (game.room_creator_copied_at IS NOT NULL OR auth.uid() = game.creator_id)
     AND (game.room_opponent_copied_at IS NOT NULL OR auth.uid() = game.opponent_id) THEN
    INSERT INTO public.match_events(match_id, actor_id, event_type, payload)
    VALUES (game.id, auth.uid(), 'MATCH_STARTED', jsonb_build_object('deadline_minutes', 20));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_match(match_id_value UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  IF game.id IS NULL OR game.status <> 'PLAYING' OR auth.uid() NOT IN (game.creator_id, game.opponent_id) THEN
    RAISE EXCEPTION 'match cannot be finished';
  END IF;
  UPDATE public.matches
  SET status = 'COMPLETED', completed_at = COALESCE(completed_at, NOW()), payout_status = 'PENDING', last_activity_at = NOW(), updated_at = NOW()
  WHERE id = game.id;
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload)
  VALUES (game.id, auth.uid(), 'MATCH_FINISHED', jsonb_build_object('reason', 'player_or_timer'));
  PERFORM public.create_notification(game.creator_id, 'MATCH', 'انتهت المباراة', 'انتقلا الآن إلى صفحة تصريح النتيجة.', '/matches/' || game.id, 'match:finished:' || game.id);
  PERFORM public.create_notification(game.opponent_id, 'MATCH', 'انتهت المباراة', 'انتقلا الآن إلى صفحة تصريح النتيجة.', '/matches/' || game.id, 'match:finished:' || game.id || ':opponent');
END;
$$;

CREATE OR REPLACE FUNCTION public.expire_match_lifecycle_system()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game RECORD; total INTEGER := 0; next_status TEXT; reason TEXT;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  FOR game IN
    SELECT * FROM public.matches
    WHERE status = 'PLAYING'
      AND ((room_code IS NULL AND room_setup_deadline_at IS NOT NULL AND room_setup_deadline_at <= NOW())
        OR (room_code IS NOT NULL AND match_deadline_at IS NOT NULL AND match_deadline_at <= NOW()))
    FOR UPDATE
  LOOP
    next_status := CASE WHEN game.room_code IS NULL THEN 'DISPUTE' ELSE 'COMPLETED' END;
    reason := CASE WHEN game.room_code IS NULL THEN 'انتهت مهلة إنشاء الغرفة' ELSE 'انتهت مهلة المباراة' END;
    UPDATE public.matches
    SET status = next_status,
        completed_at = COALESCE(completed_at, NOW()),
        payout_status = 'PENDING',
        payout_note = reason,
        last_activity_at = NOW(),
        updated_at = NOW()
    WHERE id = game.id;
    INSERT INTO public.match_events(match_id, actor_id, event_type, payload)
    VALUES (game.id, NULL, CASE WHEN game.room_code IS NULL THEN 'ROOM_SETUP_EXPIRED' ELSE 'MATCH_TIMER_EXPIRED' END, jsonb_build_object('reason', reason));
    PERFORM public.create_notification(game.creator_id, 'MATCH', reason, 'تم نقل المباراة إلى مراجعة الإدارة.', '/matches/' || game.id, 'match:lifecycle-expired:' || game.id);
    IF game.opponent_id IS NOT NULL THEN
      PERFORM public.create_notification(game.opponent_id, 'MATCH', reason, 'تم نقل المباراة إلى مراجعة الإدارة.', '/matches/' || game.id, 'match:lifecycle-expired:' || game.id || ':opponent');
    END IF;
    total := total + 1;
  END LOOP;
  RETURN total;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_match_room(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_match_room_copy(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finish_match(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.expire_match_lifecycle_system() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_match_lifecycle_system() TO service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'arena-expire-match-lifecycle';
SELECT cron.schedule('arena-expire-match-lifecycle', '* * * * *', 'SELECT public.expire_match_lifecycle_system();');

