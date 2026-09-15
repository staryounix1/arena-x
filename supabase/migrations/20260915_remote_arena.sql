-- Production migration for Supabase Auth, wallet operations, moderation and evidence.

ALTER TABLE public.users ALTER COLUMN password_hash DROP NOT NULL;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS banned BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS ban_reason TEXT NOT NULL DEFAULT '';
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS last_login TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users (id, username, email, password_hash, role, balance, efootball_id, whatsapp, wins, losses, banned)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'username', ''), split_part(NEW.email, '@', 1)),
    NEW.email,
    '',
    'PLAYER',
    0,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'efootball_id', ''), 'EF-000000'),
    COALESCE(NEW.raw_user_meta_data->>'whatsapp', ''),
    0,
    0,
    FALSE
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND role = 'ADMIN' AND banned = FALSE
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

CREATE OR REPLACE FUNCTION public.find_login_email(login_identifier TEXT)
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT email
  FROM public.users
  WHERE (LOWER(email) = LOWER(login_identifier) OR LOWER(username) = LOWER(login_identifier))
    AND banned = FALSE
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.find_login_email(TEXT) TO anon, authenticated;

DROP POLICY IF EXISTS "Users can view own profile" ON public.users;
DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
DROP POLICY IF EXISTS "Admins can view all users" ON public.users;
DROP POLICY IF EXISTS "Admins can update all users" ON public.users;
CREATE POLICY "Users and admins can view profiles" ON public.users FOR SELECT USING (auth.uid() = id OR public.is_admin());
CREATE POLICY "Users can create own profile" ON public.users FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users and admins can update profiles" ON public.users FOR UPDATE USING (auth.uid() = id OR public.is_admin()) WITH CHECK (auth.uid() = id OR public.is_admin());

DROP POLICY IF EXISTS "Admins can view all matches" ON public.matches;
DROP POLICY IF EXISTS "Match participants can update match" ON public.matches;
CREATE POLICY "Admins can view all matches safely" ON public.matches FOR SELECT USING (public.is_admin());
CREATE POLICY "Match participants and admins can update" ON public.matches FOR UPDATE USING (auth.uid() = creator_id OR auth.uid() = opponent_id OR public.is_admin());

DROP POLICY IF EXISTS "Admins can view all messages" ON public.match_messages;
CREATE POLICY "Admins can view all messages safely" ON public.match_messages FOR SELECT USING (public.is_admin());

DROP POLICY IF EXISTS "Admins can view all transactions" ON public.transactions;
CREATE POLICY "Admins can view all transactions safely" ON public.transactions FOR SELECT USING (public.is_admin());

DROP POLICY IF EXISTS "Admins can view all recharges" ON public.recharges;
DROP POLICY IF EXISTS "Admins can update recharges" ON public.recharges;
CREATE POLICY "Admins can view all recharges safely" ON public.recharges FOR SELECT USING (public.is_admin());
CREATE POLICY "Admins can update recharges safely" ON public.recharges FOR UPDATE USING (public.is_admin());

DROP POLICY IF EXISTS "Admins can manage tournaments" ON public.tournaments;
CREATE POLICY "Admins can manage tournaments safely" ON public.tournaments FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Admins can view all participations" ON public.tournament_participants;
CREATE POLICY "Admins can view all participations safely" ON public.tournament_participants FOR SELECT USING (public.is_admin());
DROP POLICY IF EXISTS "Admins can manage settings" ON public.settings;
CREATE POLICY "Admins can manage settings safely" ON public.settings FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

CREATE TABLE IF NOT EXISTS public.withdrawals (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  username VARCHAR(100) NOT NULL,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  method VARCHAR(50) NOT NULL,
  destination VARCHAR(255) NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.disputes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  username VARCHAR(100) NOT NULL,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  subject VARCHAR(255) NOT NULL,
  details TEXT NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'UNDER_REVIEW', 'RESOLVED', 'REJECTED')),
  resolution TEXT,
  evidence JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.dispute_evidence (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  dispute_id UUID NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,
  file_path TEXT NOT NULL,
  file_url TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  original_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.activity_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  username VARCHAR(100) NOT NULL,
  category VARCHAR(30) NOT NULL,
  action VARCHAR(120) NOT NULL,
  description TEXT NOT NULL,
  amount DECIMAL(15,2),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispute_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can create own withdrawal" ON public.withdrawals FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users and admins can view withdrawals" ON public.withdrawals FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "Admins can update withdrawals" ON public.withdrawals FOR UPDATE USING (public.is_admin());
CREATE POLICY "Users can create own dispute" ON public.disputes FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users and admins can view disputes" ON public.disputes FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "Admins can update disputes" ON public.disputes FOR UPDATE USING (public.is_admin());
CREATE POLICY "Users can create own evidence" ON public.dispute_evidence FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM public.disputes WHERE id = dispute_id AND user_id = auth.uid()));
CREATE POLICY "Dispute participants and admins can view evidence" ON public.dispute_evidence FOR SELECT USING (EXISTS (SELECT 1 FROM public.disputes WHERE id = dispute_id AND (user_id = auth.uid() OR public.is_admin())));
CREATE POLICY "Users and admins can create activity" ON public.activity_logs FOR INSERT WITH CHECK (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "Users and admins can view activity" ON public.activity_logs FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON public.withdrawals(status);
CREATE INDEX IF NOT EXISTS idx_withdrawals_user_id ON public.withdrawals(user_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status ON public.disputes(status);
CREATE INDEX IF NOT EXISTS idx_disputes_user_id ON public.disputes(user_id);
CREATE INDEX IF NOT EXISTS idx_activity_logs_created_at ON public.activity_logs(created_at DESC);

INSERT INTO storage.buckets (id, name, public)
VALUES ('dispute-evidence', 'dispute-evidence', TRUE)
ON CONFLICT (id) DO UPDATE SET public = TRUE;

DROP POLICY IF EXISTS "Authenticated users can upload dispute evidence" ON storage.objects;
DROP POLICY IF EXISTS "Users can view dispute evidence" ON storage.objects;
CREATE POLICY "Authenticated users can upload dispute evidence" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'dispute-evidence' AND (storage.foldername(name))[1] = auth.uid()::text);
CREATE POLICY "Users can view dispute evidence" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'dispute-evidence' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.is_admin()));

CREATE OR REPLACE FUNCTION public.change_balance(target_user_id UUID, delta_amount NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE next_balance NUMERIC;
BEGIN
  IF NOT public.is_admin() AND (target_user_id <> auth.uid() OR delta_amount >= 0) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF NOT public.is_admin() AND (SELECT balance + delta_amount FROM public.users WHERE id = target_user_id) < 0 THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  UPDATE public.users SET balance = balance + delta_amount, updated_at = NOW() WHERE id = target_user_id RETURNING balance INTO next_balance;
  IF next_balance IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (target_user_id, 'BALANCE', 'تعديل رصيد', delta_amount, next_balance);
  RETURN next_balance;
END;
$$;

DROP FUNCTION IF EXISTS public.request_withdrawal(NUMERIC, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.request_withdrawal(withdrawal_id_value UUID, amount_value NUMERIC, method_value TEXT, destination_value TEXT, notes_value TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE new_id UUID; current_balance NUMERIC; profile_name TEXT;
BEGIN
  SELECT balance, username INTO current_balance, profile_name FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF current_balance IS NULL OR current_balance < amount_value OR amount_value <= 0 THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  UPDATE public.users SET balance = balance - amount_value, updated_at = NOW() WHERE id = auth.uid();
  INSERT INTO public.withdrawals (id, username, user_id, amount, method, destination, notes) VALUES (withdrawal_id_value, profile_name, auth.uid(), amount_value, method_value, destination_value, notes_value) RETURNING id INTO new_id;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'WITHDRAWAL', 'طلب سحب قيد المراجعة', -amount_value, current_balance - amount_value);
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.review_recharge(recharge_id UUID, approve BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE item public.recharges%ROWTYPE; next_balance NUMERIC;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  SELECT * INTO item FROM public.recharges WHERE id = recharge_id FOR UPDATE;
  IF item.id IS NULL OR item.status <> 'PENDING' THEN RAISE EXCEPTION 'request is not pending'; END IF;
  UPDATE public.recharges SET status = CASE WHEN approve THEN 'APPROVED' ELSE 'REJECTED' END, updated_at = NOW() WHERE id = recharge_id;
  IF approve THEN UPDATE public.users SET balance = balance + item.amount, updated_at = NOW() WHERE id = item.user_id RETURNING balance INTO next_balance; INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (item.user_id, 'RECHARGE', 'اعتماد طلب الشحن', item.amount, next_balance); END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.review_withdrawal(withdrawal_id UUID, approve BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE item public.withdrawals%ROWTYPE; next_balance NUMERIC;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  SELECT * INTO item FROM public.withdrawals WHERE id = withdrawal_id FOR UPDATE;
  IF item.id IS NULL OR item.status <> 'PENDING' THEN RAISE EXCEPTION 'request is not pending'; END IF;
  UPDATE public.withdrawals SET status = CASE WHEN approve THEN 'APPROVED' ELSE 'REJECTED' END, updated_at = NOW() WHERE id = withdrawal_id;
  IF NOT approve THEN UPDATE public.users SET balance = balance + item.amount, updated_at = NOW() WHERE id = item.user_id RETURNING balance INTO next_balance; INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (item.user_id, 'WITHDRAWAL_REFUND', 'إعادة مبلغ طلب السحب المرفوض', item.amount, next_balance); END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_user_banned(target_user_id UUID, is_banned BOOLEAN, reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  UPDATE public.users SET banned = is_banned, ban_reason = CASE WHEN is_banned THEN COALESCE(reason, '') ELSE '' END, updated_at = NOW() WHERE id = target_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.join_match(match_id_value UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE; player public.users%ROWTYPE; next_balance NUMERIC;
BEGIN
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  SELECT * INTO player FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF game.id IS NULL OR game.status <> 'OPEN' OR game.creator_id = auth.uid() THEN RAISE EXCEPTION 'match is not available'; END IF;
  IF player.balance < game.stake THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  next_balance := player.balance - game.stake;
  UPDATE public.users SET balance = next_balance, updated_at = NOW() WHERE id = auth.uid();
  UPDATE public.matches SET status = 'PLAYING', opponent_id = auth.uid(), opponent_name = player.username, opponent_efootball_id = player.efootball_id, updated_at = NOW() WHERE id = match_id_value;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'MATCH', 'حجز قيمة المباراة', -game.stake, next_balance);
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
  SELECT * INTO cup FROM public.tournaments WHERE id = tournament_id_value FOR UPDATE;
  SELECT * INTO player FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF cup.id IS NULL OR cup.participant_count >= cup.max_players OR EXISTS (SELECT 1 FROM public.tournament_participants WHERE tournament_id = tournament_id_value AND user_id = auth.uid()) THEN RAISE EXCEPTION 'tournament is not available'; END IF;
  IF player.balance < cup.entry_fee THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  next_balance := player.balance - cup.entry_fee;
  UPDATE public.users SET balance = next_balance, updated_at = NOW() WHERE id = auth.uid();
  INSERT INTO public.tournament_participants (tournament_id, user_id) VALUES (tournament_id_value, auth.uid());
  UPDATE public.tournaments SET participant_count = participant_count + 1, updated_at = NOW() WHERE id = tournament_id_value;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'TOURNAMENT', 'رسوم التسجيل في البطولة', -cup.entry_fee, next_balance);
END;
$$;

GRANT EXECUTE ON FUNCTION public.change_balance(UUID, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_recharge(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_withdrawal(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_banned(UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_match(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_tournament(UUID) TO authenticated;
