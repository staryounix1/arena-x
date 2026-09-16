-- Expire open matches from the database instead of relying on a visitor's browser.

CREATE OR REPLACE FUNCTION public.expire_open_matches_system()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game RECORD;
  total INTEGER := 0;
  current_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  FOR game IN
    SELECT *
    FROM public.matches
    WHERE status = 'OPEN'
      AND expires_at IS NOT NULL
      AND expires_at <= NOW()
    FOR UPDATE
  LOOP
    UPDATE public.users
    SET balance = balance + game.stake, updated_at = NOW()
    WHERE id = game.creator_id
    RETURNING balance INTO current_balance;

    UPDATE public.matches
    SET status = 'CANCELLED',
        cancelled_at = NOW(),
        cancel_reason = 'انتهت مهلة انتظار المنافس',
        escrow_status = 'REFUNDED',
        settled_at = NOW(),
        updated_at = NOW()
    WHERE id = game.id;

    INSERT INTO public.transactions(user_id, type, description, amount, balance_after)
    VALUES (game.creator_id, 'MATCH_REFUND', 'إعادة رهان المباراة بعد انتهاء المهلة', game.stake, current_balance);
    INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id)
    VALUES (game.creator_id, 'MATCH_REFUND', 'match', game.id, game.stake, current_balance, 'match:expire:' || game.id, NULL);
    INSERT INTO public.match_events(match_id, actor_id, event_type, payload)
    VALUES (game.id, NULL, 'EXPIRED', '{}'::jsonb);
    PERFORM public.create_notification(game.creator_id, 'MATCH', 'انتهت مهلة المباراة', 'تمت إعادة مبلغ الرهان لأن المنافس لم ينضم.', '/matches/' || game.id, 'match:expired:' || game.id);
    total := total + 1;
  END LOOP;
  RETURN total;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_open_matches() FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.expire_open_matches_system() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_open_matches_system() TO service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'arena-expire-open-matches';
SELECT cron.schedule('arena-expire-open-matches', '*/5 * * * *', 'SELECT public.expire_open_matches_system();');
