-- Profiles, identity verification and configurable payment methods.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS favorite_team VARCHAR(80) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS favorite_team_logo VARCHAR(120) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS verification_status VARCHAR(20) NOT NULL DEFAULT 'UNVERIFIED'
    CHECK (verification_status IN ('UNVERIFIED', 'PENDING', 'APPROVED', 'REJECTED')),
  ADD COLUMN IF NOT EXISTS whatsapp_verified_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.payment_methods (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  kind VARCHAR(20) NOT NULL CHECK (kind IN ('RECHARGE', 'WITHDRAWAL')),
  name VARCHAR(100) NOT NULL,
  details TEXT NOT NULL DEFAULT '',
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_methods_kind_order
  ON public.payment_methods(kind, sort_order, created_at);
ALTER TABLE public.payment_methods
  ADD CONSTRAINT payment_methods_kind_name_unique UNIQUE (kind, name);

ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public can view enabled payment methods" ON public.payment_methods;
CREATE POLICY "Public can view enabled payment methods"
  ON public.payment_methods FOR SELECT
  USING (enabled OR public.is_admin());
DROP POLICY IF EXISTS "Admins can manage payment methods" ON public.payment_methods;
CREATE POLICY "Admins can manage payment methods"
  ON public.payment_methods FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

INSERT INTO public.payment_methods(kind, name, details, sort_order)
SELECT 'RECHARGE', 'التحويل البنكي',
       'اسم المستفيد: ' || COALESCE((SELECT value FROM public.settings WHERE key = 'cih_name'), 'إدارة ARENA//X') || E'\nRIB: ' || COALESCE((SELECT value FROM public.settings WHERE key = 'cih_rib'), 'سيتم تحديده من الإدارة'),
       10
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE kind = 'RECHARGE' AND name = 'التحويل البنكي');

INSERT INTO public.payment_methods(kind, name, details, sort_order)
SELECT 'RECHARGE', 'Cash Plus',
       'اسم المستفيد: ' || COALESCE((SELECT value FROM public.settings WHERE key = 'cashplus_name'), 'إدارة ARENA//X') || E'\nرقم التعريف: ' || COALESCE((SELECT value FROM public.settings WHERE key = 'cashplus_cin'), 'سيتم تحديده من الإدارة'),
       20
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE kind = 'RECHARGE' AND name = 'Cash Plus');

INSERT INTO public.payment_methods(kind, name, details, sort_order)
VALUES ('WITHDRAWAL', 'التحويل البنكي', 'سيتم التحويل إلى الحساب الذي تدخله في طلب السحب.', 10),
       ('WITHDRAWAL', 'Cash Plus', 'سيتم التحويل إلى رقم الهاتف أو الحساب الذي تدخله في طلب السحب.', 20)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.identity_verifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  whatsapp VARCHAR(50) NOT NULL,
  whatsapp_code VARCHAR(12) NOT NULL,
  document_path TEXT NOT NULL,
  document_name VARCHAR(255) NOT NULL,
  document_mime VARCHAR(120) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  admin_note TEXT NOT NULL DEFAULT '',
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at TIMESTAMPTZ,
  reviewed_by UUID REFERENCES public.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_identity_verifications_status
  ON public.identity_verifications(status, submitted_at DESC);

ALTER TABLE public.identity_verifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own identity verification" ON public.identity_verifications;
CREATE POLICY "Users can view own identity verification"
  ON public.identity_verifications FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS "Users can submit identity verification" ON public.identity_verifications;
CREATE POLICY "Users can submit identity verification"
  ON public.identity_verifications FOR INSERT
  WITH CHECK (auth.uid() = user_id AND status = 'PENDING');
DROP POLICY IF EXISTS "Users can update pending identity verification" ON public.identity_verifications;
CREATE POLICY "Users can update pending identity verification"
  ON public.identity_verifications FOR UPDATE
  USING (auth.uid() = user_id OR public.is_admin())
  WITH CHECK (public.is_admin() OR (auth.uid() = user_id AND status IN ('PENDING', 'REJECTED')));

INSERT INTO storage.buckets (id, name, public)
VALUES ('identity-documents', 'identity-documents', FALSE)
ON CONFLICT (id) DO UPDATE SET public = FALSE;

DROP POLICY IF EXISTS "Users can upload own identity document" ON storage.objects;
CREATE POLICY "Users can upload own identity document"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'identity-documents' AND (storage.foldername(name))[1] = auth.uid()::text);
DROP POLICY IF EXISTS "Users and admins can view identity documents" ON storage.objects;
CREATE POLICY "Users and admins can view identity documents"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'identity-documents' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.is_admin()));

CREATE OR REPLACE FUNCTION public.sync_identity_verification_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET verification_status = CASE WHEN NEW.status = 'APPROVED' THEN 'APPROVED' WHEN NEW.status = 'REJECTED' THEN 'REJECTED' ELSE 'PENDING' END,
      whatsapp_verified_at = CASE WHEN NEW.status = 'APPROVED' THEN COALESCE(whatsapp_verified_at, NOW()) ELSE NULL END,
      updated_at = NOW()
  WHERE id = NEW.user_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_identity_verification_status ON public.identity_verifications;
CREATE TRIGGER sync_identity_verification_status
AFTER INSERT OR UPDATE OF status ON public.identity_verifications
FOR EACH ROW EXECUTE FUNCTION public.sync_identity_verification_status();

CREATE OR REPLACE FUNCTION public.guard_verified_match_players()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE creator_status TEXT;
DECLARE opponent_status TEXT;
BEGIN
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;
  SELECT verification_status INTO creator_status FROM public.users WHERE id = NEW.creator_id;
  IF creator_status IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION 'account verification required';
  END IF;
  IF NEW.opponent_id IS NOT NULL THEN
    SELECT verification_status INTO opponent_status FROM public.users WHERE id = NEW.opponent_id;
    IF opponent_status IS DISTINCT FROM 'APPROVED' THEN
      RAISE EXCEPTION 'account verification required';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_verified_match_players ON public.matches;
CREATE TRIGGER guard_verified_match_players
BEFORE INSERT OR UPDATE OF creator_id, opponent_id ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.guard_verified_match_players();
