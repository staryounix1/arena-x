-- Persistent tournament scheduling, payments, reminders, analytics and safer settings.

ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS start_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS end_at TIMESTAMPTZ;

WITH ordered AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY created_at, id) AS position
  FROM public.tournaments
  WHERE start_at IS NULL
)
UPDATE public.tournaments AS tournaments
SET start_at = NOW() + ((ordered.position - 1) * INTERVAL '1 day') + INTERVAL '20 hours'
FROM ordered
WHERE tournaments.id = ordered.id;

CREATE INDEX IF NOT EXISTS idx_tournaments_start_at ON public.tournaments(start_at);

ALTER TABLE public.store_orders
  ADD COLUMN IF NOT EXISTS payment_status VARCHAR(20) NOT NULL DEFAULT 'UNPAID'
    CHECK (payment_status IN ('UNPAID', 'PENDING', 'PAID', 'FAILED', 'REFUNDED')),
  ADD COLUMN IF NOT EXISTS payment_transaction_id UUID;

ALTER TABLE public.recharges
  ADD COLUMN IF NOT EXISTS payment_status VARCHAR(20) NOT NULL DEFAULT 'UNPAID'
    CHECK (payment_status IN ('UNPAID', 'PENDING', 'PAID', 'FAILED', 'REFUNDED')),
  ADD COLUMN IF NOT EXISTS payment_transaction_id UUID;

CREATE TABLE IF NOT EXISTS public.payment_transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  provider VARCHAR(40) NOT NULL DEFAULT 'STRIPE',
  provider_session_id TEXT UNIQUE,
  reference_type VARCHAR(40) NOT NULL CHECK (reference_type IN ('RECHARGE', 'COIN_RECHARGE', 'STORE_ORDER')),
  reference_id UUID NOT NULL,
  amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
  currency VARCHAR(10) NOT NULL DEFAULT 'usd',
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PAID', 'FAILED', 'EXPIRED', 'REFUNDED')),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  paid_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_payment_transactions_user_created
  ON public.payment_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_payment_transactions_status
  ON public.payment_transactions(status, created_at DESC);
ALTER TABLE public.payment_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own payment transactions" ON public.payment_transactions;
CREATE POLICY "Users can view own payment transactions"
  ON public.payment_transactions FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());

CREATE TABLE IF NOT EXISTS public.tournament_reminders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  channel VARCHAR(20) NOT NULL CHECK (channel IN ('IN_APP', 'EMAIL', 'WHATSAPP')),
  remind_at TIMESTAMPTZ NOT NULL,
  sent_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, tournament_id, channel)
);

CREATE INDEX IF NOT EXISTS idx_tournament_reminders_due
  ON public.tournament_reminders(remind_at) WHERE sent_at IS NULL;
ALTER TABLE public.tournament_reminders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own tournament reminders" ON public.tournament_reminders;
CREATE POLICY "Users can view own tournament reminders"
  ON public.tournament_reminders FOR SELECT USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS "Users can manage own tournament reminders" ON public.tournament_reminders;
CREATE POLICY "Users can manage own tournament reminders"
  ON public.tournament_reminders FOR ALL
  USING (auth.uid() = user_id OR public.is_admin())
  WITH CHECK (auth.uid() = user_id OR public.is_admin());

CREATE OR REPLACE FUNCTION public.subscribe_tournament_reminder(tournament_id_value UUID, channel_value TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE tournament_start TIMESTAMPTZ; reminder_id UUID;
BEGIN
  IF auth.uid() IS NULL OR channel_value NOT IN ('IN_APP', 'EMAIL', 'WHATSAPP') THEN
    RAISE EXCEPTION 'invalid reminder request';
  END IF;
  SELECT start_at INTO tournament_start FROM public.tournaments WHERE id = tournament_id_value;
  IF tournament_start IS NULL THEN RAISE EXCEPTION 'tournament has no scheduled start'; END IF;
  INSERT INTO public.tournament_reminders(user_id, tournament_id, channel, remind_at)
  VALUES (auth.uid(), tournament_id_value, channel_value, GREATEST(NOW(), tournament_start - INTERVAL '30 minutes'))
  ON CONFLICT (user_id, tournament_id, channel) DO UPDATE SET remind_at = EXCLUDED.remind_at, sent_at = NULL
  RETURNING id INTO reminder_id;
  RETURN reminder_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.subscribe_tournament_reminder(UUID, TEXT) TO authenticated;

CREATE TABLE IF NOT EXISTS public.analytics_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  session_id TEXT,
  event_name VARCHAR(100) NOT NULL,
  route TEXT NOT NULL DEFAULT '',
  properties JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_analytics_events_created ON public.analytics_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_events_name ON public.analytics_events(event_name, created_at DESC);
ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can view analytics events" ON public.analytics_events;
CREATE POLICY "Admins can view analytics events"
  ON public.analytics_events FOR SELECT USING (public.is_admin());

CREATE OR REPLACE FUNCTION public.record_analytics_event(event_name_value TEXT, route_value TEXT, properties_value JSONB DEFAULT '{}'::jsonb, session_id_value TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE event_id UUID;
BEGIN
  IF NULLIF(TRIM(event_name_value), '') IS NULL THEN RAISE EXCEPTION 'event name required'; END IF;
  INSERT INTO public.analytics_events(user_id, session_id, event_name, route, properties)
  VALUES (auth.uid(), NULLIF(session_id_value, ''), LEFT(event_name_value, 100), LEFT(COALESCE(route_value, ''), 300), COALESCE(properties_value, '{}'::jsonb))
  RETURNING id INTO event_id;
  RETURN event_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.record_analytics_event(TEXT, TEXT, JSONB, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_settings_for_session()
RETURNS TABLE(key TEXT, value TEXT, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  IF public.is_admin() THEN
    RETURN QUERY SELECT settings.key::TEXT, settings.value::TEXT, settings.updated_at FROM public.settings;
  ELSE
    RETURN QUERY
    SELECT settings.key::TEXT, settings.value::TEXT, settings.updated_at
    FROM public.settings
    WHERE settings.key = ANY(ARRAY[
      'whatsapp_mode', 'whatsapp_direct_link', 'online_count_mode', 'online_count_manual',
      'recharge_amounts', 'cih_name', 'cih_rib', 'cashplus_name', 'cashplus_cin',
      'featured_matches', 'store_accounts', 'store_recharge_packages', 'store_live_slots'
    ]);
  END IF;
END;
$$;

DROP POLICY IF EXISTS "Anyone can view platform settings" ON public.settings;
DROP POLICY IF EXISTS "Anyone can view settings" ON public.settings;
REVOKE SELECT ON public.settings FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_settings_for_session() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_public_testimonials()
RETURNS TABLE(username TEXT, score INTEGER, comment TEXT, created_at TIMESTAMPTZ)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT LEFT(COALESCE(users.username, 'لاعب ARENA//X'), 100), ratings.score, LEFT(ratings.comment, 300), ratings.created_at
  FROM public.ratings
  JOIN public.users ON users.id = ratings.reviewee_id
  WHERE ratings.comment IS NOT NULL AND LENGTH(TRIM(ratings.comment)) > 0
  ORDER BY ratings.created_at DESC
  LIMIT 12;
$$;
GRANT EXECUTE ON FUNCTION public.get_public_testimonials() TO anon, authenticated;

DROP TRIGGER IF EXISTS update_payment_transactions_updated_at ON public.payment_transactions;
CREATE TRIGGER update_payment_transactions_updated_at
  BEFORE UPDATE ON public.payment_transactions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
