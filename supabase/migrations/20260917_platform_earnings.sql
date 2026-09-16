-- Platform wallet: immutable commission records for matches, tournaments and withdrawals.

CREATE TABLE IF NOT EXISTS public.platform_earnings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  source_type VARCHAR(20) NOT NULL CHECK (source_type IN ('MATCH', 'TOURNAMENT', 'WITHDRAWAL')),
  source_id UUID NOT NULL,
  user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
  tournament_id UUID REFERENCES public.tournaments(id) ON DELETE SET NULL,
  withdrawal_id UUID REFERENCES public.withdrawals(id) ON DELETE SET NULL,
  gross_amount NUMERIC(15,2) NOT NULL CHECK (gross_amount >= 0),
  commission_rate NUMERIC(8,5) NOT NULL CHECK (commission_rate >= 0),
  commission_amount NUMERIC(15,2) NOT NULL CHECK (commission_amount >= 0),
  net_amount NUMERIC(15,2) NOT NULL CHECK (net_amount >= 0),
  description TEXT NOT NULL,
  dedupe_key VARCHAR(220) NOT NULL UNIQUE,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.withdrawals
  ADD COLUMN IF NOT EXISTS withdrawal_fee NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS payout_amount NUMERIC(15,2) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_platform_earnings_created_at
  ON public.platform_earnings(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_platform_earnings_source_type
  ON public.platform_earnings(source_type, created_at DESC);

ALTER TABLE public.platform_earnings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can view platform earnings" ON public.platform_earnings;
CREATE POLICY "Admins can view platform earnings"
  ON public.platform_earnings FOR SELECT USING (public.is_admin());

CREATE OR REPLACE FUNCTION public.record_match_platform_earning()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rate NUMERIC;
  gross NUMERIC;
  commission NUMERIC;
BEGIN
  IF NEW.payout_status = 'APPROVED' AND OLD.payout_status IS DISTINCT FROM 'APPROVED' THEN
    SELECT COALESCE(value::NUMERIC, 0.10) INTO rate FROM public.settings WHERE key = 'commission_rate';
    gross := ROUND(NEW.stake * 2, 2);
    commission := GREATEST(ROUND(gross - NEW.prize, 2), 0);
    INSERT INTO public.platform_earnings(source_type, source_id, user_id, match_id, gross_amount, commission_rate, commission_amount, net_amount, description, dedupe_key, metadata)
    VALUES ('MATCH', NEW.id, NEW.winner_id, NEW.id, gross, rate, commission, NEW.prize, 'عمولة منصة من المباراة #' || NEW.id, 'match:' || NEW.id, jsonb_build_object('match_id', NEW.id, 'stake', NEW.stake, 'prize', NEW.prize, 'winner_id', NEW.winner_id))
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS record_match_platform_earning ON public.matches;
CREATE TRIGGER record_match_platform_earning
  AFTER UPDATE OF payout_status ON public.matches
  FOR EACH ROW EXECUTE FUNCTION public.record_match_platform_earning();

CREATE OR REPLACE FUNCTION public.prepare_withdrawal_payout()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED' THEN
    NEW.withdrawal_fee := ROUND(NEW.amount * 0.05, 2);
    NEW.payout_amount := ROUND(NEW.amount - NEW.withdrawal_fee, 2);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prepare_withdrawal_payout ON public.withdrawals;
CREATE TRIGGER prepare_withdrawal_payout
  BEFORE UPDATE OF status ON public.withdrawals
  FOR EACH ROW EXECUTE FUNCTION public.prepare_withdrawal_payout();

CREATE OR REPLACE FUNCTION public.record_withdrawal_platform_earning()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED' THEN
    INSERT INTO public.platform_earnings(source_type, source_id, user_id, withdrawal_id, gross_amount, commission_rate, commission_amount, net_amount, description, dedupe_key, metadata)
    VALUES ('WITHDRAWAL', NEW.id, NEW.user_id, NEW.id, NEW.amount, 0.05, NEW.withdrawal_fee, NEW.payout_amount, 'عمولة سحب 5% من الطلب #' || NEW.id, 'withdrawal:' || NEW.id, jsonb_build_object('withdrawal_id', NEW.id, 'requested_amount', NEW.amount, 'payout_amount', NEW.payout_amount))
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS record_withdrawal_platform_earning ON public.withdrawals;
CREATE TRIGGER record_withdrawal_platform_earning
  AFTER UPDATE OF status ON public.withdrawals
  FOR EACH ROW EXECUTE FUNCTION public.record_withdrawal_platform_earning();

CREATE OR REPLACE FUNCTION public.record_tournament_platform_earning()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  entry_amount NUMERIC;
  rate NUMERIC;
  commission NUMERIC;
BEGIN
  SELECT entry_fee INTO entry_amount FROM public.tournaments WHERE id = NEW.tournament_id;
  SELECT COALESCE(value::NUMERIC, 0.10) INTO rate FROM public.settings WHERE key = 'commission_rate';
  entry_amount := COALESCE(entry_amount, 0);
  commission := ROUND(entry_amount * rate, 2);
  INSERT INTO public.platform_earnings(source_type, source_id, user_id, tournament_id, gross_amount, commission_rate, commission_amount, net_amount, description, dedupe_key, metadata)
  VALUES ('TOURNAMENT', NEW.id, NEW.user_id, NEW.tournament_id, entry_amount, rate, commission, GREATEST(entry_amount - commission, 0), 'عمولة منصة من تسجيل بطولة #' || NEW.tournament_id, 'tournament-entry:' || NEW.id, jsonb_build_object('tournament_id', NEW.tournament_id, 'participant_id', NEW.id, 'entry_fee', entry_amount))
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS record_tournament_platform_earning ON public.tournament_participants;
CREATE TRIGGER record_tournament_platform_earning
  AFTER INSERT ON public.tournament_participants
  FOR EACH ROW EXECUTE FUNCTION public.record_tournament_platform_earning();
