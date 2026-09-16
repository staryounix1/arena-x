-- Keep uploaded dispute evidence private and expose it through short-lived signed URLs.

INSERT INTO storage.buckets (id, name, public)
VALUES ('dispute-evidence', 'dispute-evidence', FALSE)
ON CONFLICT (id) DO UPDATE SET public = FALSE;
