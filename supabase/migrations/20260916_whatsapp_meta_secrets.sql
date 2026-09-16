-- Keep Meta credentials out of the public settings table.
CREATE TABLE IF NOT EXISTS public.whatsapp_secrets (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id = TRUE),
  access_token TEXT NOT NULL,
  phone_number_id TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.whatsapp_secrets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.whatsapp_secrets FROM anon, authenticated;
