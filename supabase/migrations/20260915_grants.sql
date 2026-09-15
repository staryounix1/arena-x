-- PostgREST table privileges for the roles protected by the RLS policies.

GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT ON public.matches, public.tournaments TO anon;
GRANT SELECT ON public.settings TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE ON
  public.users,
  public.matches,
  public.match_messages,
  public.tournaments,
  public.tournament_participants,
  public.transactions,
  public.recharges,
  public.settings,
  public.withdrawals,
  public.disputes,
  public.dispute_evidence,
  public.activity_logs
TO authenticated;
