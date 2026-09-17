-- Store account orders with an explicit review and delivery lifecycle.

CREATE TABLE IF NOT EXISTS public.store_orders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL,
  account_title TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT '',
  price NUMERIC(15,2) NOT NULL CHECK (price > 0),
  status VARCHAR(20) NOT NULL DEFAULT 'NEW'
    CHECK (status IN ('NEW', 'UNDER_REVIEW', 'DELIVERED', 'CANCELLED')),
  customer_note TEXT NOT NULL DEFAULT '',
  admin_note TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_store_orders_user_created
  ON public.store_orders(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_store_orders_status_created
  ON public.store_orders(status, created_at DESC);

ALTER TABLE public.store_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own store orders" ON public.store_orders;
CREATE POLICY "Users can view own store orders"
  ON public.store_orders FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "Users can create own store orders" ON public.store_orders;
CREATE POLICY "Users can create own store orders"
  ON public.store_orders FOR INSERT
  WITH CHECK (auth.uid() = user_id AND status = 'NEW');

DROP POLICY IF EXISTS "Admins can update store orders" ON public.store_orders;
CREATE POLICY "Admins can update store orders"
  ON public.store_orders FOR UPDATE
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE OR REPLACE FUNCTION public.create_store_order(
  order_id_value UUID,
  account_id_value TEXT,
  account_title_value TEXT,
  platform_value TEXT,
  price_value NUMERIC,
  customer_note_value TEXT DEFAULT ''
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE existing_id UUID;
BEGIN
  IF auth.uid() IS NULL OR order_id_value IS NULL OR account_id_value IS NULL
     OR account_title_value IS NULL OR price_value IS NULL OR price_value <= 0 THEN
    RAISE EXCEPTION 'invalid store order';
  END IF;

  SELECT id INTO existing_id
  FROM public.store_orders
  WHERE user_id = auth.uid()
    AND account_id = account_id_value
    AND status IN ('NEW', 'UNDER_REVIEW')
  ORDER BY created_at DESC
  LIMIT 1;
  IF existing_id IS NOT NULL THEN RETURN existing_id; END IF;

  INSERT INTO public.store_orders(
    id, user_id, account_id, account_title, platform, price, customer_note
  )
  VALUES (
    order_id_value, auth.uid(), account_id_value, account_title_value,
    COALESCE(platform_value, ''), price_value, COALESCE(customer_note_value, '')
  );
  RETURN order_id_value;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_store_order(
  store_order_id UUID,
  status_value TEXT,
  admin_note_value TEXT DEFAULT ''
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  IF status_value NOT IN ('NEW', 'UNDER_REVIEW', 'DELIVERED', 'CANCELLED') THEN
    RAISE EXCEPTION 'invalid store order status';
  END IF;

  UPDATE public.store_orders
  SET status = status_value,
      admin_note = COALESCE(admin_note_value, ''),
      updated_at = NOW(),
      reviewed_at = CASE WHEN status_value IN ('UNDER_REVIEW', 'DELIVERED', 'CANCELLED') THEN COALESCE(reviewed_at, NOW()) ELSE reviewed_at END,
      delivered_at = CASE WHEN status_value = 'DELIVERED' THEN COALESCE(delivered_at, NOW()) ELSE delivered_at END,
      cancelled_at = CASE WHEN status_value = 'CANCELLED' THEN COALESCE(cancelled_at, NOW()) ELSE cancelled_at END
  WHERE id = store_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'store order not found'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.create_store_order(UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_store_order(UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_update_store_order(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_store_order(UUID, TEXT, TEXT) TO authenticated;
