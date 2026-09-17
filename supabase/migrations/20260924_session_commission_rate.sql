-- Expose the platform commission rate to non-admin sessions.
--
-- The pricing/payout preview in the store and the "الإدارة والتسعير" admin form
-- read `commission_rate` from the settings map returned by get_settings_for_session().
-- That key was missing from the non-admin allow-list, so every non-admin session
-- silently fell back to the hardcoded client default (0.10) while create_match()
-- priced matches from the stored value (0.15). Players therefore saw a prize
-- preview that did not match what they were actually awarded.
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
      'commission_rate'
    ]);
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_settings_for_session() TO anon, authenticated;
