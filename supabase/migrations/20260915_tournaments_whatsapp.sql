-- Tournament management fields, image storage and WhatsApp notification deduplication.

ALTER TABLE public.tournaments ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT '';
ALTER TABLE public.tournaments ADD COLUMN IF NOT EXISTS image_url TEXT NOT NULL DEFAULT '';
ALTER TABLE public.tournaments ADD COLUMN IF NOT EXISTS platform VARCHAR(50) NOT NULL DEFAULT 'الهاتف';
ALTER TABLE public.tournaments ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'UPCOMING';
ALTER TABLE public.tournaments ADD COLUMN IF NOT EXISTS end_date VARCHAR(100) NOT NULL DEFAULT '';
ALTER TABLE public.tournaments ADD COLUMN IF NOT EXISTS featured BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_tournaments_status ON public.tournaments(status);

INSERT INTO storage.buckets (id, name, public)
VALUES ('tournament-assets', 'tournament-assets', TRUE)
ON CONFLICT (id) DO UPDATE SET public = TRUE;

DROP POLICY IF EXISTS "Admins can upload tournament assets" ON storage.objects;
DROP POLICY IF EXISTS "Anyone can view tournament assets" ON storage.objects;
DROP POLICY IF EXISTS "Admins can update tournament assets" ON storage.objects;
DROP POLICY IF EXISTS "Admins can delete tournament assets" ON storage.objects;
CREATE POLICY "Admins can upload tournament assets" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'tournament-assets' AND public.is_admin());
CREATE POLICY "Anyone can view tournament assets" ON storage.objects FOR SELECT USING (bucket_id = 'tournament-assets');
CREATE POLICY "Admins can update tournament assets" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'tournament-assets' AND public.is_admin()) WITH CHECK (bucket_id = 'tournament-assets' AND public.is_admin());
CREATE POLICY "Admins can delete tournament assets" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'tournament-assets' AND public.is_admin());

CREATE TABLE IF NOT EXISTS public.whatsapp_notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  event_key TEXT NOT NULL UNIQUE,
  event_type VARCHAR(40) NOT NULL,
  reference_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.whatsapp_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can view WhatsApp notifications" ON public.whatsapp_notifications;
CREATE POLICY "Admins can view WhatsApp notifications" ON public.whatsapp_notifications FOR SELECT USING (public.is_admin());
