-- Extend payment methods with a delivery mode (manual / electronic) and an
-- optional icon, and add settings keys that enable or disable each mode as a
-- whole. Existing rows default to MANUAL so nothing changes for them.

ALTER TABLE public.payment_methods
  ADD COLUMN IF NOT EXISTS mode TEXT NOT NULL DEFAULT 'MANUAL';

ALTER TABLE public.payment_methods
  ADD COLUMN IF NOT EXISTS icon_url TEXT NOT NULL DEFAULT '';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'payment_methods_mode_check'
      AND conrelid = 'public.payment_methods'::regclass
  ) THEN
    ALTER TABLE public.payment_methods
      ADD CONSTRAINT payment_methods_mode_check
      CHECK (mode IN ('MANUAL', 'ELECTRONIC'));
  END IF;
END $$;

-- Mode-level switches, stored in the existing settings key/value table.
INSERT INTO public.settings (key, value)
VALUES ('payment_manual_enabled', 'true')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.settings (key, value)
VALUES ('payment_electronic_enabled', 'false')
ON CONFLICT (key) DO NOTHING;

-- Expose the new keys to non-admin sessions alongside the other public settings.
CREATE OR REPLACE FUNCTION public.get_settings_for_session()
RETURNS TABLE(key TEXT, value TEXT, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
      'featured_matches', 'store_accounts', 'store_recharge_packages', 'store_live_slots',
      'commission_rate', 'payment_manual_enabled', 'payment_electronic_enabled', 'home_arena', 'recharge_form'
    ]);
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_settings_for_session() TO anon, authenticated;
