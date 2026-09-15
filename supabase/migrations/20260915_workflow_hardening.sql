-- Keep workflow records searchable and their modification timestamps accurate.

DROP TRIGGER IF EXISTS update_withdrawals_updated_at ON public.withdrawals;
CREATE TRIGGER update_withdrawals_updated_at
  BEFORE UPDATE ON public.withdrawals
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_disputes_updated_at ON public.disputes;
CREATE TRIGGER update_disputes_updated_at
  BEFORE UPDATE ON public.disputes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX IF NOT EXISTS idx_recharges_status_created_at
  ON public.recharges(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_disputes_status_created_at
  ON public.disputes(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dispute_evidence_dispute_id
  ON public.dispute_evidence(dispute_id);

DROP POLICY IF EXISTS "Anyone can view platform settings" ON public.settings;
CREATE POLICY "Anyone can view platform settings"
  ON public.settings FOR SELECT USING (TRUE);

-- Let the dashboard receive changes immediately, with polling as a fallback.
DO $$
DECLARE table_name TEXT;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH table_name IN ARRAY ARRAY[
      'users', 'matches', 'match_messages', 'tournaments',
      'tournament_participants', 'transactions', 'recharges',
      'withdrawals', 'disputes', 'dispute_evidence', 'activity_logs', 'settings'
    ] LOOP
      IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = table_name
      ) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', table_name);
      END IF;
    END LOOP;
  END IF;
END
$$;
