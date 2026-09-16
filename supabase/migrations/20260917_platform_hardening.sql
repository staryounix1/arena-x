-- Platform hardening: trusted wallet operations, match lifecycle, audit, support,
-- notifications, ratings, fraud signals and legal consent.

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancel_reason TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS settled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS escrow_status VARCHAR(20) NOT NULL DEFAULT 'NONE'
    CHECK (escrow_status IN ('NONE', 'HELD', 'RELEASED', 'REFUNDED')),
  ADD COLUMN IF NOT EXISTS last_activity_at TIMESTAMPTZ;

UPDATE public.matches
SET expires_at = COALESCE(expires_at, created_at + INTERVAL '30 minutes'),
    last_activity_at = COALESCE(last_activity_at, updated_at, created_at)
WHERE expires_at IS NULL OR last_activity_at IS NULL;

ALTER TABLE public.recharges
  ADD CONSTRAINT recharges_amount_positive CHECK (amount > 0);

CREATE TABLE IF NOT EXISTS public.wallet_ledger (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  operation_type VARCHAR(50) NOT NULL,
  reference_type VARCHAR(50),
  reference_id UUID,
  amount NUMERIC(15,2) NOT NULL,
  balance_after NUMERIC(15,2) NOT NULL,
  idempotency_key VARCHAR(180) NOT NULL UNIQUE,
  actor_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.audit_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  actor_role VARCHAR(20),
  action VARCHAR(120) NOT NULL,
  entity_type VARCHAR(60) NOT NULL,
  entity_id TEXT,
  before_data JSONB,
  after_data JSONB,
  amount NUMERIC(15,2),
  request_id UUID,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind VARCHAR(50) NOT NULL,
  title VARCHAR(180) NOT NULL,
  body TEXT NOT NULL,
  link TEXT,
  dedupe_key VARCHAR(180),
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_dedupe
  ON public.notifications(user_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.match_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  actor_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  event_type VARCHAR(60) NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.match_result_claims (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  claimant_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  winner_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.ratings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  reviewee_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
  comment TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(match_id, reviewer_id)
);

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS rating_average NUMERIC(3,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rating_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS risk_score INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS trust_level VARCHAR(20) NOT NULL DEFAULT 'NEW'
    CHECK (trust_level IN ('NEW', 'STARTER', 'TRUSTED', 'VERIFIED', 'RESTRICTED'));

CREATE TABLE IF NOT EXISTS public.support_tickets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  subject VARCHAR(180) NOT NULL,
  category VARCHAR(50) NOT NULL DEFAULT 'GENERAL',
  status VARCHAR(20) NOT NULL DEFAULT 'OPEN'
    CHECK (status IN ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED')),
  priority VARCHAR(20) NOT NULL DEFAULT 'NORMAL'
    CHECK (priority IN ('LOW', 'NORMAL', 'HIGH', 'URGENT')),
  assigned_to UUID REFERENCES public.users(id) ON DELETE SET NULL,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.support_ticket_messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ticket_id UUID NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  message TEXT NOT NULL,
  internal_note BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.security_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  event_type VARCHAR(60) NOT NULL,
  severity VARCHAR(20) NOT NULL DEFAULT 'INFO'
    CHECK (severity IN ('INFO', 'WARNING', 'CRITICAL')),
  ip_hash TEXT,
  fingerprint_hash TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.error_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  message TEXT NOT NULL,
  stack TEXT,
  route TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.terms_acceptances (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  document_key VARCHAR(80) NOT NULL,
  document_version VARCHAR(30) NOT NULL,
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, document_key, document_version)
);

CREATE TABLE IF NOT EXISTS public.tournament_rounds (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  name VARCHAR(100) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'ACTIVE', 'COMPLETED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(tournament_id, round_number)
);

CREATE TABLE IF NOT EXISTS public.tournament_matches (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  round_id UUID REFERENCES public.tournament_rounds(id) ON DELETE SET NULL,
  match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
  slot_number INTEGER NOT NULL,
  player_one_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  player_two_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  winner_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'READY', 'PLAYING', 'COMPLETED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(tournament_id, slot_number)
);

CREATE INDEX IF NOT EXISTS idx_wallet_ledger_user_created ON public.wallet_ledger(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_created ON public.audit_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_match_events_match_created ON public.match_events(match_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_support_tickets_status ON public.support_tickets(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_user_created ON public.security_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_error_events_created ON public.error_events(created_at DESC);

ALTER TABLE public.wallet_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_result_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_ticket_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.error_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.terms_acceptances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own wallet ledger" ON public.wallet_ledger;
CREATE POLICY "Users can view own wallet ledger" ON public.wallet_ledger FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS "Admins can view audit events" ON public.audit_events;
CREATE POLICY "Admins can view audit events" ON public.audit_events FOR SELECT USING (public.is_admin());
DROP POLICY IF EXISTS "Users can view own notifications" ON public.notifications;
CREATE POLICY "Users can view own notifications" ON public.notifications FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS "Users can update own notifications" ON public.notifications;
CREATE POLICY "Users can update own notifications" ON public.notifications FOR UPDATE USING (auth.uid() = user_id OR public.is_admin()) WITH CHECK (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS "Participants can view match events" ON public.match_events;
CREATE POLICY "Participants can view match events" ON public.match_events FOR SELECT USING (EXISTS (SELECT 1 FROM public.matches m WHERE m.id = match_id AND (m.creator_id = auth.uid() OR m.opponent_id = auth.uid())) OR public.is_admin());
DROP POLICY IF EXISTS "Participants can view claims" ON public.match_result_claims;
CREATE POLICY "Participants can view claims" ON public.match_result_claims FOR SELECT USING (EXISTS (SELECT 1 FROM public.matches m WHERE m.id = match_id AND (m.creator_id = auth.uid() OR m.opponent_id = auth.uid())) OR public.is_admin());
DROP POLICY IF EXISTS "Users can view ratings" ON public.ratings;
CREATE POLICY "Users can view ratings" ON public.ratings FOR SELECT USING (true);
DROP POLICY IF EXISTS "Participants can create ratings" ON public.ratings;
CREATE POLICY "Participants can create ratings" ON public.ratings FOR INSERT WITH CHECK (reviewer_id = auth.uid() AND EXISTS (SELECT 1 FROM public.matches m WHERE m.id = match_id AND m.status = 'COMPLETED' AND (m.creator_id = auth.uid() OR m.opponent_id = auth.uid()) AND reviewee_id IN (m.creator_id, m.opponent_id) AND reviewee_id <> auth.uid()));
DROP POLICY IF EXISTS "Users can view own support tickets" ON public.support_tickets;
CREATE POLICY "Users can view own support tickets" ON public.support_tickets FOR SELECT USING (user_id = auth.uid() OR public.is_admin());
DROP POLICY IF EXISTS "Users can create support tickets" ON public.support_tickets;
CREATE POLICY "Users can create support tickets" ON public.support_tickets FOR INSERT WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS "Admins can update support tickets" ON public.support_tickets;
CREATE POLICY "Admins can update support tickets" ON public.support_tickets FOR UPDATE USING (public.is_admin());
DROP POLICY IF EXISTS "Users can view ticket messages" ON public.support_ticket_messages;
CREATE POLICY "Users can view ticket messages" ON public.support_ticket_messages FOR SELECT USING (EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id AND (t.user_id = auth.uid() OR public.is_admin())) AND (NOT internal_note OR public.is_admin()));
DROP POLICY IF EXISTS "Ticket participants can send messages" ON public.support_ticket_messages;
CREATE POLICY "Ticket participants can send messages" ON public.support_ticket_messages FOR INSERT WITH CHECK (user_id = auth.uid() AND EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id AND (t.user_id = auth.uid() OR public.is_admin())));
DROP POLICY IF EXISTS "Users can create error events" ON public.error_events;
CREATE POLICY "Users can create error events" ON public.error_events FOR INSERT WITH CHECK (user_id = auth.uid() OR user_id IS NULL);
DROP POLICY IF EXISTS "Admins can view error events" ON public.error_events;
CREATE POLICY "Admins can view error events" ON public.error_events FOR SELECT USING (public.is_admin());
DROP POLICY IF EXISTS "Users can view own terms" ON public.terms_acceptances;
CREATE POLICY "Users can view own terms" ON public.terms_acceptances FOR SELECT USING (user_id = auth.uid() OR public.is_admin());
DROP POLICY IF EXISTS "Users can accept terms" ON public.terms_acceptances;
CREATE POLICY "Users can accept terms" ON public.terms_acceptances FOR INSERT WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS "Public can view tournament rounds" ON public.tournament_rounds;
CREATE POLICY "Public can view tournament rounds" ON public.tournament_rounds FOR SELECT USING (true);
DROP POLICY IF EXISTS "Public can view tournament matches" ON public.tournament_matches;
CREATE POLICY "Public can view tournament matches" ON public.tournament_matches FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins can manage tournament rounds" ON public.tournament_rounds;
CREATE POLICY "Admins can manage tournament rounds" ON public.tournament_rounds FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Admins can manage tournament matches" ON public.tournament_matches;
CREATE POLICY "Admins can manage tournament matches" ON public.tournament_matches FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

CREATE OR REPLACE FUNCTION public.guard_user_sensitive_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_setting('app.trusted_rpc', true) <> '1' AND NOT public.is_admin() AND auth.uid() = OLD.id THEN
    NEW.role := OLD.role;
    NEW.balance := OLD.balance;
    NEW.wins := OLD.wins;
    NEW.losses := OLD.losses;
    NEW.banned := OLD.banned;
    NEW.ban_reason := OLD.ban_reason;
    NEW.password_hash := OLD.password_hash;
    NEW.rating_average := OLD.rating_average;
    NEW.rating_count := OLD.rating_count;
    NEW.risk_score := OLD.risk_score;
    NEW.trust_level := OLD.trust_level;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_user_sensitive_fields_trigger ON public.users;
CREATE TRIGGER guard_user_sensitive_fields_trigger
BEFORE UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.guard_user_sensitive_fields();

CREATE OR REPLACE FUNCTION public.flag_duplicate_profiles()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE duplicate_count INTEGER := 0;
BEGIN
  IF NEW.efootball_id <> 'EF-000000' THEN
    SELECT COUNT(*) INTO duplicate_count FROM public.users WHERE id <> NEW.id AND efootball_id = NEW.efootball_id;
  END IF;
  IF duplicate_count > 0 OR (NULLIF(NEW.whatsapp, '') IS NOT NULL AND EXISTS (SELECT 1 FROM public.users WHERE id <> NEW.id AND whatsapp = NEW.whatsapp)) THEN
    INSERT INTO public.security_events(user_id, event_type, severity, metadata) VALUES (NEW.id, 'DUPLICATE_PROFILE_SIGNAL', 'WARNING', jsonb_build_object('efootball_id', NEW.efootball_id));
    PERFORM set_config('app.trusted_rpc', '1', true);
    UPDATE public.users SET risk_score = risk_score + 25, trust_level = CASE WHEN risk_score + 25 >= 50 THEN 'RESTRICTED' ELSE trust_level END WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS flag_duplicate_profiles_trigger ON public.users;
CREATE TRIGGER flag_duplicate_profiles_trigger
AFTER INSERT ON public.users
FOR EACH ROW EXECUTE FUNCTION public.flag_duplicate_profiles();

CREATE OR REPLACE FUNCTION public.guard_match_sensitive_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_setting('app.trusted_rpc', true) <> '1' AND NOT public.is_admin() THEN
    NEW.creator_id := OLD.creator_id;
    NEW.creator_name := OLD.creator_name;
    NEW.creator_efootball_id := OLD.creator_efootball_id;
    NEW.opponent_id := OLD.opponent_id;
    NEW.opponent_name := OLD.opponent_name;
    NEW.opponent_efootball_id := OLD.opponent_efootball_id;
    NEW.stake := OLD.stake;
    NEW.prize := OLD.prize;
    NEW.status := OLD.status;
    NEW.winner_id := OLD.winner_id;
    NEW.winner_name := OLD.winner_name;
    NEW.payout_status := OLD.payout_status;
    NEW.payout_note := OLD.payout_note;
    NEW.escrow_status := OLD.escrow_status;
    NEW.settled_at := OLD.settled_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_match_sensitive_fields_trigger ON public.matches;
CREATE TRIGGER guard_match_sensitive_fields_trigger
BEFORE UPDATE ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.guard_match_sensitive_fields();

CREATE OR REPLACE FUNCTION public.append_audit_event(
  action_value TEXT,
  entity_type_value TEXT,
  entity_id_value TEXT,
  before_value JSONB DEFAULT NULL,
  after_value JSONB DEFAULT NULL,
  amount_value NUMERIC DEFAULT NULL,
  request_id_value UUID DEFAULT NULL,
  metadata_value JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE event_id UUID;
BEGIN
  INSERT INTO public.audit_events(actor_id, actor_role, action, entity_type, entity_id, before_data, after_data, amount, request_id, metadata)
  SELECT auth.uid(), role, action_value, entity_type_value, entity_id_value, before_value, after_value, amount_value, request_id_value, COALESCE(metadata_value, '{}'::jsonb)
  FROM public.users WHERE id = auth.uid()
  RETURNING id INTO event_id;
  RETURN event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_notification(
  user_id_value UUID,
  kind_value TEXT,
  title_value TEXT,
  body_value TEXT,
  link_value TEXT DEFAULT NULL,
  dedupe_key_value TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE notification_id UUID;
BEGIN
  INSERT INTO public.notifications(user_id, kind, title, body, link, dedupe_key)
  VALUES (user_id_value, kind_value, title_value, body_value, link_value, dedupe_key_value)
  ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
  RETURNING id INTO notification_id;
  RETURN notification_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_recharge_request(
  recharge_id_value UUID,
  amount_value NUMERIC,
  method_value TEXT,
  whatsapp_value TEXT,
  notes_value TEXT DEFAULT ''
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE profile_name TEXT; created_id UUID;
BEGIN
  IF auth.uid() IS NULL OR amount_value <= 0 OR amount_value > 100000 THEN RAISE EXCEPTION 'invalid recharge'; END IF;
  SELECT username INTO profile_name FROM public.users WHERE id = auth.uid() AND banned = FALSE;
  IF profile_name IS NULL THEN RAISE EXCEPTION 'account unavailable'; END IF;
  INSERT INTO public.recharges(id, username, user_id, amount, payment_method, whatsapp, notes)
  VALUES (recharge_id_value, profile_name, auth.uid(), amount_value, method_value, whatsapp_value, COALESCE(notes_value, ''))
  RETURNING id INTO created_id;
  PERFORM public.append_audit_event('CREATE_RECHARGE', 'recharge', created_id::TEXT, NULL, jsonb_build_object('amount', amount_value, 'method', method_value), amount_value, recharge_id_value);
  RETURN created_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_match(
  match_id_value UUID,
  title_value TEXT,
  stake_value NUMERIC,
  platform_value TEXT
)
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

CREATE OR REPLACE FUNCTION public.cancel_match(match_id_value UUID, reason_value TEXT DEFAULT '')
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE; current_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  IF game.id IS NULL OR game.creator_id <> auth.uid() OR game.status <> 'OPEN' THEN RAISE EXCEPTION 'match cannot be cancelled'; END IF;
  UPDATE public.users SET balance = balance + game.stake, updated_at = NOW() WHERE id = game.creator_id RETURNING balance INTO current_balance;
  UPDATE public.matches SET status = 'CANCELLED', cancelled_at = NOW(), cancel_reason = COALESCE(reason_value, ''), escrow_status = 'REFUNDED', settled_at = NOW(), updated_at = NOW() WHERE id = game.id;
  INSERT INTO public.transactions(user_id, type, description, amount, balance_after) VALUES (game.creator_id, 'MATCH_REFUND', 'إعادة رهان المباراة الملغاة', game.stake, current_balance);
  INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (game.creator_id, 'MATCH_REFUND', 'match', game.id, game.stake, current_balance, 'match:cancel:' || game.id, auth.uid());
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload) VALUES (game.id, auth.uid(), 'CANCELLED', jsonb_build_object('reason', reason_value));
END;
$$;

CREATE OR REPLACE FUNCTION public.expire_open_matches()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game RECORD; total INTEGER := 0; current_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
  FOR game IN SELECT * FROM public.matches WHERE status = 'OPEN' AND expires_at IS NOT NULL AND expires_at <= NOW() FOR UPDATE LOOP
    UPDATE public.users SET balance = balance + game.stake, updated_at = NOW() WHERE id = game.creator_id RETURNING balance INTO current_balance;
    UPDATE public.matches SET status = 'CANCELLED', cancelled_at = NOW(), cancel_reason = 'انتهت مهلة انتظار المنافس', escrow_status = 'REFUNDED', settled_at = NOW(), updated_at = NOW() WHERE id = game.id;
    INSERT INTO public.transactions(user_id, type, description, amount, balance_after) VALUES (game.creator_id, 'MATCH_REFUND', 'إعادة رهان المباراة بعد انتهاء المهلة', game.stake, current_balance);
    INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (game.creator_id, 'MATCH_REFUND', 'match', game.id, game.stake, current_balance, 'match:expire:' || game.id, auth.uid());
    INSERT INTO public.match_events(match_id, actor_id, event_type, payload) VALUES (game.id, auth.uid(), 'EXPIRED', '{}'::jsonb);
    PERFORM public.create_notification(game.creator_id, 'MATCH', 'انتهت مهلة المباراة', 'تمت إعادة مبلغ الرهان لأن المنافس لم ينضم.', '/matches/' || game.id, 'match:expired:' || game.id);
    total := total + 1;
  END LOOP;
  RETURN total;
END;
$$;

CREATE OR REPLACE FUNCTION public.open_dispute_secure(
  dispute_id_value UUID,
  match_id_value UUID,
  subject_value TEXT,
  details_value TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE; profile_name TEXT;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO game FROM public.matches WHERE id = match_id_value;
  SELECT username INTO profile_name FROM public.users WHERE id = auth.uid() AND banned = FALSE;
  IF game.id IS NULL OR profile_name IS NULL OR (game.creator_id <> auth.uid() AND game.opponent_id <> auth.uid()) THEN RAISE EXCEPTION 'dispute not allowed'; END IF;
  INSERT INTO public.disputes(id, match_id, username, user_id, subject, details, status) VALUES (dispute_id_value, match_id_value, profile_name, auth.uid(), subject_value, details_value, 'OPEN');
  UPDATE public.matches SET status = 'DISPUTE', updated_at = NOW() WHERE id = match_id_value AND status IN ('PLAYING', 'COMPLETED');
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload) VALUES (match_id_value, auth.uid(), 'DISPUTE_OPENED', jsonb_build_object('dispute_id', dispute_id_value));
  PERFORM public.append_audit_event('OPEN_DISPUTE', 'dispute', dispute_id_value::TEXT, NULL, jsonb_build_object('match_id', match_id_value, 'subject', subject_value));
  RETURN dispute_id_value;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_player_rating(
  match_id_value UUID,
  reviewee_id_value UUID,
  score_value INTEGER,
  comment_value TEXT DEFAULT ''
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE rating_id UUID; game public.matches%ROWTYPE;
BEGIN
  SELECT * INTO game FROM public.matches WHERE id = match_id_value;
  IF game.id IS NULL OR game.status <> 'COMPLETED' OR auth.uid() NOT IN (game.creator_id, game.opponent_id) OR reviewee_id_value NOT IN (game.creator_id, game.opponent_id) OR reviewee_id_value = auth.uid() THEN RAISE EXCEPTION 'rating not allowed'; END IF;
  INSERT INTO public.ratings(match_id, reviewer_id, reviewee_id, score, comment) VALUES (match_id_value, auth.uid(), reviewee_id_value, score_value, COALESCE(comment_value, '')) RETURNING id INTO rating_id;
  UPDATE public.users SET rating_average = (SELECT ROUND(AVG(score)::NUMERIC, 2) FROM public.ratings WHERE reviewee_id = reviewee_id_value), rating_count = (SELECT COUNT(*) FROM public.ratings WHERE reviewee_id = reviewee_id_value), trust_level = CASE WHEN (SELECT COUNT(*) FROM public.ratings WHERE reviewee_id = reviewee_id_value) >= 10 AND (SELECT AVG(score) FROM public.ratings WHERE reviewee_id = reviewee_id_value) >= 4.5 THEN 'VERIFIED' WHEN (SELECT COUNT(*) FROM public.ratings WHERE reviewee_id = reviewee_id_value) >= 3 THEN 'TRUSTED' ELSE 'STARTER' END, updated_at = NOW() WHERE id = reviewee_id_value;
  RETURN rating_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_support_ticket(
  ticket_id_value UUID,
  subject_value TEXT,
  category_value TEXT,
  message_value TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NULLIF(TRIM(subject_value), '') IS NULL OR NULLIF(TRIM(message_value), '') IS NULL THEN RAISE EXCEPTION 'invalid support ticket'; END IF;
  INSERT INTO public.support_tickets(id, user_id, subject, category) VALUES (ticket_id_value, auth.uid(), TRIM(subject_value), COALESCE(NULLIF(category_value, ''), 'GENERAL'));
  INSERT INTO public.support_ticket_messages(ticket_id, user_id, message) VALUES (ticket_id_value, auth.uid(), TRIM(message_value));
  RETURN ticket_id_value;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_security_event(event_type_value TEXT, severity_value TEXT DEFAULT 'INFO', metadata_value JSONB DEFAULT '{}'::jsonb)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE event_id UUID;
BEGIN
  INSERT INTO public.security_events(user_id, event_type, severity, metadata) VALUES (auth.uid(), event_type_value, COALESCE(severity_value, 'INFO'), COALESCE(metadata_value, '{}'::jsonb)) RETURNING id INTO event_id;
  RETURN event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_terms(document_key_value TEXT, document_version_value TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE acceptance_id UUID;
BEGIN
  INSERT INTO public.terms_acceptances(user_id, document_key, document_version) VALUES (auth.uid(), document_key_value, document_version_value)
  ON CONFLICT (user_id, document_key, document_version) DO UPDATE SET accepted_at = NOW()
  RETURNING id INTO acceptance_id;
  RETURN acceptance_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_client_error(message_value TEXT, stack_value TEXT DEFAULT NULL, route_value TEXT DEFAULT '/', metadata_value JSONB DEFAULT '{}'::jsonb)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE error_id UUID;
BEGIN
  INSERT INTO public.error_events(user_id, message, stack, route, metadata) VALUES (auth.uid(), LEFT(message_value, 1000), LEFT(stack_value, 5000), LEFT(route_value, 300), COALESCE(metadata_value, '{}'::jsonb)) RETURNING id INTO error_id;
  RETURN error_id;
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
  PERFORM set_config('app.trusted_rpc', '1', true);
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  SELECT * INTO player FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF game.id IS NULL OR game.status <> 'OPEN' OR game.creator_id = auth.uid() OR game.expires_at <= NOW() OR player.id IS NULL OR player.banned OR player.trust_level = 'RESTRICTED' THEN RAISE EXCEPTION 'match is not available'; END IF;
  IF player.balance < game.stake THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  next_balance := player.balance - game.stake;
  UPDATE public.users SET balance = next_balance, updated_at = NOW() WHERE id = auth.uid();
  UPDATE public.matches SET status = 'PLAYING', opponent_id = auth.uid(), opponent_name = player.username, opponent_efootball_id = player.efootball_id, started_at = NOW(), last_activity_at = NOW(), escrow_status = 'HELD', updated_at = NOW() WHERE id = match_id_value;
  INSERT INTO public.transactions (user_id, type, description, amount, balance_after) VALUES (auth.uid(), 'MATCH_ESCROW', 'حجز قيمة المباراة', -game.stake, next_balance);
  INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (auth.uid(), 'MATCH_ESCROW', 'match', game.id, -game.stake, next_balance, 'match:join:' || game.id || ':' || auth.uid(), auth.uid());
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload) VALUES (game.id, auth.uid(), 'JOINED', jsonb_build_object('opponent_id', auth.uid()));
  PERFORM public.create_notification(game.creator_id, 'MATCH', 'انضم منافس إلى مباراتك', 'أصبحت المباراة جارية ويمكنكما بدء المواجهة.', '/matches/' || game.id, 'match:joined:' || game.id);
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

CREATE OR REPLACE FUNCTION public.review_match_payout(match_id_value UUID, approve BOOLEAN, note_value TEXT DEFAULT '')
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE game public.matches%ROWTYPE; winner_balance NUMERIC; creator_balance NUMERIC; opponent_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  SELECT * INTO game FROM public.matches WHERE id = match_id_value FOR UPDATE;
  IF game.id IS NULL OR game.winner_id IS NULL OR game.payout_status = 'APPROVED' OR game.settled_at IS NOT NULL THEN RAISE EXCEPTION 'match payout is not available'; END IF;
  IF approve THEN
    UPDATE public.users SET balance = balance + game.prize, wins = wins + 1, updated_at = NOW() WHERE id = game.winner_id RETURNING balance INTO winner_balance;
    INSERT INTO public.transactions(user_id, type, description, amount, balance_after) VALUES (game.winner_id, 'MATCH_PAYOUT', 'اعتماد جائزة المباراة', game.prize, winner_balance);
    INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (game.winner_id, 'MATCH_PAYOUT', 'match', game.id, game.prize, winner_balance, 'match:payout:' || game.id, auth.uid());
    UPDATE public.users SET losses = losses + 1, updated_at = NOW() WHERE id IN (game.creator_id, game.opponent_id) AND id <> game.winner_id;
    UPDATE public.matches SET status = 'COMPLETED', payout_status = 'APPROVED', payout_note = COALESCE(note_value, ''), payout_reviewed_at = NOW(), completed_at = NOW(), settled_at = NOW(), escrow_status = 'RELEASED', updated_at = NOW() WHERE id = game.id;
  ELSE
    UPDATE public.users SET balance = balance + game.stake, updated_at = NOW() WHERE id = game.creator_id RETURNING balance INTO creator_balance;
    INSERT INTO public.transactions(user_id, type, description, amount, balance_after) VALUES (game.creator_id, 'MATCH_REFUND', 'إعادة رهان المباراة بعد رفض الجائزة', game.stake, creator_balance);
    INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (game.creator_id, 'MATCH_REFUND', 'match', game.id, game.stake, creator_balance, 'match:refund:creator:' || game.id, auth.uid());
    IF game.opponent_id IS NOT NULL THEN
      UPDATE public.users SET balance = balance + game.stake, updated_at = NOW() WHERE id = game.opponent_id RETURNING balance INTO opponent_balance;
      INSERT INTO public.transactions(user_id, type, description, amount, balance_after) VALUES (game.opponent_id, 'MATCH_REFUND', 'إعادة رهان المباراة بعد رفض الجائزة', game.stake, opponent_balance);
      INSERT INTO public.wallet_ledger(user_id, operation_type, reference_type, reference_id, amount, balance_after, idempotency_key, actor_id) VALUES (game.opponent_id, 'MATCH_REFUND', 'match', game.id, game.stake, opponent_balance, 'match:refund:opponent:' || game.id, auth.uid());
    END IF;
    UPDATE public.matches SET status = 'DISPUTE', payout_status = 'REJECTED', payout_note = COALESCE(note_value, ''), payout_reviewed_at = NOW(), settled_at = NOW(), escrow_status = 'REFUNDED', updated_at = NOW() WHERE id = game.id;
  END IF;
  INSERT INTO public.match_events(match_id, actor_id, event_type, payload) VALUES (game.id, auth.uid(), CASE WHEN approve THEN 'PAYOUT_APPROVED' ELSE 'PAYOUT_REFUNDED' END, jsonb_build_object('note', note_value));
  PERFORM public.append_audit_event(CASE WHEN approve THEN 'APPROVE_MATCH_PAYOUT' ELSE 'REFUND_MATCH_PAYOUT' END, 'match', game.id::TEXT, to_jsonb(game), jsonb_build_object('note', note_value));
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_recharge_request(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_match(UUID, TEXT, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_match(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.expire_open_matches() TO authenticated;
GRANT EXECUTE ON FUNCTION public.open_dispute_secure(UUID, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_player_rating(UUID, UUID, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_support_ticket(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_security_event(TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_terms(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_client_error(TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.join_match(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_match_payout(UUID, BOOLEAN, TEXT) TO authenticated;
