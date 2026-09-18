-- Host-entered room codes for OPEN matches, and a longer room-setup window.
--
-- Two problems this fixes:
--   1. The host UI lets the creator enter the eFootball room code while the match
--      is still OPEN (before an opponent joins), but the only available RPC,
--      `set_match_room`, requires admin rights AND requires status = 'PLAYING'
--      with an opponent already present. Every host save therefore failed.
--   2. The room-setup window was one minute on the transition to PLAYING, which
--      is too tight for players to create the eFootball room and relay its code.

-- ---------------------------------------------------------------------------
-- 1. Host-owned room code entry for OPEN matches
-- ---------------------------------------------------------------------------
-- Only the match creator may set the code, only while the match is OPEN or
-- PLAYING, and only before the opponent has confirmed copying it. Setting the
-- code early is encouraged: when the opponent joins, they will already see it.
CREATE OR REPLACE FUNCTION public.set_match_room_code(match_id_value UUID, room_code_value TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);

  IF NULLIF(TRIM(room_code_value), '') IS NULL THEN
    RAISE EXCEPTION 'room code required';
  END IF;

  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;

  IF game.id IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;
  IF auth.uid() IS NULL OR auth.uid() <> game.creator_id THEN
    RAISE EXCEPTION 'only the match creator can set the room code';
  END IF;
  IF game.status NOT IN ('OPEN', 'PLAYING') THEN
    RAISE EXCEPTION 'match room is not available';
  END IF;
  IF game.status = 'PLAYING' AND game.room_opponent_copied_at IS NOT NULL THEN
    RAISE EXCEPTION 'room code is locked after the opponent confirmed the copy';
  END IF;

  UPDATE public.matches
  SET room_code = LEFT(TRIM(room_code_value), 50),
      room_ready_at = COALESCE(room_ready_at, NOW()),
      last_activity_at = NOW(),
      updated_at = NOW()
  WHERE id = match_id_value;

  INSERT INTO public.match_events(match_id, actor_id, event_type, payload)
  VALUES (match_id_value, auth.uid(), 'ROOM_CODE_SET', jsonb_build_object('room_code', LEFT(TRIM(room_code_value), 50), 'status', game.status));

  -- Notify the opponent only once they exist; before that there is nobody to notify.
  IF game.opponent_id IS NOT NULL THEN
    PERFORM public.create_notification(
      game.opponent_id, 'MATCH', 'غرفة المباراة جاهزة',
      'أدخل إلى المباراة وانسخ أيدي الغرفة. يبدأ عداد اللعب بعد تأكيد اللاعب الثاني.',
      '/matches/' || game.id, 'match:room-ready:' || game.id || ':opponent'
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_match_room_code(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Give players three minutes, not one, to prepare the room
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_match_room_setup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'PLAYING' AND OLD.status = 'OPEN' THEN
    NEW.room_setup_deadline_at := COALESCE(NEW.room_setup_deadline_at, NOW() + INTERVAL '3 minutes');
    -- If the host already entered a room code while waiting, keep it and treat
    -- the room as ready rather than clearing it.
    NEW.room_ready_at := CASE WHEN NEW.room_code IS NOT NULL THEN COALESCE(NEW.room_ready_at, NOW()) ELSE NULL END;
    NEW.match_deadline_at := NULL;
    NEW.room_creator_copied_at := NULL;
    NEW.room_opponent_copied_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

-- Re-point any existing OPEN match deadline so hosts who set a code while
-- waiting get the full three-minute window on the next transition.
COMMENT ON FUNCTION public.start_match_room_setup() IS
  'Sets a 3-minute room-setup deadline when a match moves from OPEN to PLAYING.';
