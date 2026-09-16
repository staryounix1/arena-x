-- Corrective functions for existing installations of 20260917_platform_hardening.

UPDATE public.matches
SET escrow_status = 'HELD'
WHERE escrow_status = 'NONE'
  AND status IN ('PLAYING', 'COMPLETED', 'DISPUTE')
  AND payout_status = 'PENDING';

CREATE OR REPLACE FUNCTION public.create_match(match_id_value UUID, title_value TEXT, stake_value NUMERIC, platform_value TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE player public.users%ROWTYPE; current_balance NUMERIC; commission NUMERIC; prize_value NUMERIC; created_id UUID;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO player FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF player.id IS NULL OR player.banned OR player.trust_level = 'RESTRICTED' OR stake_value < 5 OR player.balance < stake_value THEN RAISE EXCEPTION 'match cannot be created'; END IF;
  SELECT COALESCE(value::NUMERIC, 0.10) INTO commission FROM public.settings WHERE key = 'commission_rate';
  prize_value := ROUND(stake_value * 2 * (1 - commission), 2);
  UPDATE public.users SET balance = balance - stake_value, updated_at = NOW() WHERE id = auth.uid() RETURNING balance INTO current_balance;
  INSERT INTO public.matches(id, title, creator_id, creator_name, creator_efootball_id, platform, stake, prize, status, expires_at, last_activity_at, escrow_status)
  VALUES (match_id_value, COALESCE(NULLIF(title_value, ''), 'تحدٍّ جديد'), auth.uid(), player.username, player.efootball_id, platform_value, stake_value, prize_value, 'OPEN', NOW() + INTERVAL '30 minutes', NOW(), 'HELD')
  RETURNING id INTO created_id;
  INSERT INTO public.transactions(user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'MATCH_ESCROW', 'حجز رهان مباراة جديدة', -stake_value, current_balance);
  INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id, metadata)
  VALUES (auth.uid(), 'MATCH_ESCROW', 'match', created_id, -stake_value, current_balance, 'match:create:' || created_id, auth.uid(), jsonb_build_object('stake', stake_value));
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload) VALUES (created_id, auth.uid(), 'CREATED', jsonb_build_object('stake', stake_value));
  PERFORM public.append_audit_event('CREATE_MATCH', 'match', created_id::TEXT, NULL, jsonb_build_object('stake', stake_value, 'platform', platform_value), stake_value, match_id_value);
  RETURN created_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_withdrawal(withdrawal_id_value UUID, amount_value NUMERIC, method_value TEXT, destination_value TEXT, notes_value TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE new_id UUID; current_balance NUMERIC; profile_name TEXT;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT balance, username INTO current_balance, profile_name FROM public.users WHERE id = auth.uid() AND banned = FALSE AND trust_level <> 'RESTRICTED' FOR UPDATE;
  IF current_balance IS NULL OR current_balance < amount_value OR amount_value <= 0 THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  UPDATE public.users SET balance = balance - amount_value, updated_at = NOW() WHERE id = auth.uid();
  INSERT INTO public.withdrawals (id, username, user_id, amount, method, destination, notes) VALUES (withdrawal_id_value, profile_name, auth.uid(), amount_value, method_value, destination_value, notes_value) RETURNING id INTO new_id;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'WITHDRAWAL', 'طلب سحب قيد المراجعة', -amount_value, current_balance - amount_value);
  INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (auth.uid(), 'WITHDRAWAL_HOLD', 'withdrawal', new_id, -amount_value, current_balance - amount_value, 'withdrawal:' || new_id, auth.uid());
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.join_tournament(tournament_id_value UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE cup public.tournaments%ROWTYPE; player public.users%ROWTYPE; next_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO cup FROM public.tournaments WHERE id = tournament_id_value FOR UPDATE;
  SELECT * INTO player FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF cup.id IS NULL OR cup.status IN ('COMPLETED', 'CANCELLED') OR cup.participant_count >= cup.max_players OR EXISTS (SELECT 1 FROM public.tournament_participants WHERE tournament_id = tournament_id_value AND user_id = auth.uid()) OR player.banned OR player.trust_level = 'RESTRICTED' THEN RAISE EXCEPTION 'tournament is not available'; END IF;
  IF player.balance < cup.entry_fee THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  next_balance := player.balance - cup.entry_fee;
  UPDATE public.users SET balance = next_balance, updated_at = NOW() WHERE id = auth.uid();
  INSERT INTO public.tournament_participants (tournament_id, user_id) VALUES (tournament_id_value, auth.uid());
  UPDATE public.tournaments SET participant_count = participant_count + 1, updated_at = NOW() WHERE id = tournament_id_value;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'TOURNAMENT', 'رسوم التسجيل في البطولة', -cup.entry_fee, next_balance);
  INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (auth.uid(), 'TOURNAMENT_ENTRY', 'tournament', cup.id, -cup.entry_fee, next_balance, 'tournament:' || cup.id || ':' || auth.uid(), auth.uid());
END;
$$;

CREATE OR REPLACE FUNCTION public.record_login()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users SET last_login = NOW(), updated_at = NOW() WHERE id = auth.uid();
  PERFORM public.record_security_event('LOGIN_SUCCESS', 'INFO', '{}'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_match(UUID, TEXT, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_tournament(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_login() TO authenticated;
