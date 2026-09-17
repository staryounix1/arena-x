-- Wallet-backed store: pay for coin recharges and account purchases from the in-platform balance.
--
-- Before this migration the store was settlement-only: a player submitted a request, paid the
-- admin off-platform (bank transfer / Cash Plus), and an admin manually marked it approved.
-- Nothing touched the player's wallet.
--
-- This migration makes the platform balance the payment source:
--   * The price is escrowed from the buyer's balance the moment the request is created, in the
--     same transaction, behind a row lock, so two concurrent requests can never overdraw.
--   * The escrow posts a `transactions` row and an immutable `wallet_ledger` row keyed by an
--     idempotency key, matching the match-escrow convention.
--   * Cancelling (buyer) or rejecting (admin) refunds the escrow back to the wallet.
--   * Approving/delivering keeps the escrow as revenue, so no double credit happens.
--
-- `store_orders` / `recharges` gain escrow bookkeeping columns so a refund is auditable and
-- can never run twice.

-- ---------------------------------------------------------------------------
-- 1. Escrow bookkeeping on store orders and recharge requests
-- ---------------------------------------------------------------------------
ALTER TABLE public.store_orders
  ADD COLUMN IF NOT EXISTS escrow_status VARCHAR(20) NOT NULL DEFAULT 'NONE'
    CHECK (escrow_status IN ('NONE', 'HELD', 'RELEASED', 'REFUNDED')),
  ADD COLUMN IF NOT EXISTS escrow_amount NUMERIC(12, 2),
  ADD COLUMN IF NOT EXISTS escrowed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.recharges
  ADD COLUMN IF NOT EXISTS escrow_status VARCHAR(20) NOT NULL DEFAULT 'NONE'
    CHECK (escrow_status IN ('NONE', 'HELD', 'RELEASED', 'REFUNDED')),
  ADD COLUMN IF NOT EXISTS escrow_amount NUMERIC(12, 2),
  ADD COLUMN IF NOT EXISTS escrowed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES public.users(id) ON DELETE SET NULL;

-- Only wallet-funded rows carry escrow; legacy off-platform rows stay 'NONE'.
CREATE INDEX IF NOT EXISTS store_orders_escrow_idx ON public.store_orders (escrow_status) WHERE escrow_status <> 'NONE';
CREATE INDEX IF NOT EXISTS recharges_escrow_idx ON public.recharges (escrow_status) WHERE escrow_status <> 'NONE';

-- ---------------------------------------------------------------------------
-- 2. Shared escrow / refund helpers (security definer, server-authoritative)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wallet_escrow_hold(
  target_user_id UUID,
  hold_amount NUMERIC,
  operation_value TEXT,
  reference_type_value TEXT,
  reference_id_value UUID,
  idempotency_value TEXT,
  description_value TEXT
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE next_balance NUMERIC; existing_amount NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF target_user_id IS NULL OR hold_amount IS NULL OR hold_amount <= 0 THEN
    RAISE EXCEPTION 'invalid escrow amount';
  END IF;

  -- Replaying the same idempotency key must not move money twice.
  SELECT amount INTO existing_amount FROM public.wallet_ledger WHERE idempotency_key = idempotency_value;
  IF existing_amount IS NOT NULL THEN
    SELECT balance INTO next_balance FROM public.users WHERE id = target_user_id;
    RETURN next_balance;
  END IF;

  -- Lock the wallet row so concurrent holds serialize.
  PERFORM 1 FROM public.users WHERE id = target_user_id FOR UPDATE;
  SELECT balance INTO next_balance FROM public.users WHERE id = target_user_id;
  IF next_balance IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  IF next_balance < hold_amount THEN RAISE EXCEPTION 'insufficient balance'; END IF;

  UPDATE public.users
     SET balance = balance - hold_amount, updated_at = NOW()
   WHERE id = target_user_id
  RETURNING balance INTO next_balance;

  INSERT INTO public.transactions (user_id, type, description, amount, balance_after)
  VALUES (target_user_id, 'STORE_ESCROW', description_value, -hold_amount, next_balance);

  INSERT INTO public.wallet_ledger (
    user_id, operation_type, reference_type, reference_id,
    amount, balance_after, idempotency_key, actor_id, metadata
  ) VALUES (
    target_user_id, operation_value, reference_type_value, reference_id_value,
    -hold_amount, next_balance, idempotency_value, auth.uid(),
    jsonb_build_object('amount', hold_amount, 'reason', description_value)
  );

  RETURN next_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION public.wallet_escrow_refund(
  target_user_id UUID,
  refund_amount NUMERIC,
  operation_value TEXT,
  reference_type_value TEXT,
  reference_id_value UUID,
  idempotency_value TEXT,
  description_value TEXT
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE next_balance NUMERIC; existing_amount NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF target_user_id IS NULL OR refund_amount IS NULL OR refund_amount <= 0 THEN
    RAISE EXCEPTION 'invalid refund amount';
  END IF;

  SELECT amount INTO existing_amount FROM public.wallet_ledger WHERE idempotency_key = idempotency_value;
  IF existing_amount IS NOT NULL THEN
    SELECT balance INTO next_balance FROM public.users WHERE id = target_user_id;
    RETURN next_balance;
  END IF;

  UPDATE public.users
     SET balance = balance + refund_amount, updated_at = NOW()
   WHERE id = target_user_id
  RETURNING balance INTO next_balance;
  IF next_balance IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

  INSERT INTO public.transactions (user_id, type, description, amount, balance_after)
  VALUES (target_user_id, 'STORE_REFUND', description_value, refund_amount, next_balance);

  INSERT INTO public.wallet_ledger (
    user_id, operation_type, reference_type, reference_id,
    amount, balance_after, idempotency_key, actor_id, metadata
  ) VALUES (
    target_user_id, operation_value, reference_type_value, reference_id_value,
    refund_amount, next_balance, idempotency_value, auth.uid(),
    jsonb_build_object('amount', refund_amount, 'reason', description_value)
  );

  RETURN next_balance;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Store account purchase: escrow on request, refund on cancel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purchase_store_account(
  order_id_value UUID,
  account_id_value TEXT,
  account_title_value TEXT,
  platform_value TEXT,
  price_value NUMERIC,
  customer_note_value TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE caller public.users%ROWTYPE; existing_id UUID; next_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
  IF order_id_value IS NULL OR account_id_value IS NULL OR price_value IS NULL OR price_value <= 0 THEN
    RAISE EXCEPTION 'invalid store order';
  END IF;

  SELECT * INTO caller FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF caller.id IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  IF caller.banned THEN RAISE EXCEPTION 'account is banned'; END IF;

  -- One open order per account per buyer; replay returns the live order untouched.
  SELECT id INTO existing_id
    FROM public.store_orders
   WHERE user_id = auth.uid()
     AND account_id = account_id_value
     AND status IN ('NEW', 'UNDER_REVIEW')
   ORDER BY created_at DESC
   LIMIT 1;
  IF existing_id IS NOT NULL THEN RETURN existing_id; END IF;

  IF caller.balance < price_value THEN RAISE EXCEPTION 'insufficient balance'; END IF;

  next_balance := public.wallet_escrow_hold(
    auth.uid(), price_value, 'STORE_ESCROW', 'store_order', order_id_value,
    'store_order:hold:' || order_id_value, 'حجز مبلغ شراء حساب من المتجر'
  );

  INSERT INTO public.store_orders (
    id, user_id, account_id, account_title, platform, price, customer_note,
    escrow_status, escrow_amount, escrowed_at
  ) VALUES (
    order_id_value, auth.uid(), account_id_value, account_title_value,
    COALESCE(platform_value, ''), price_value, COALESCE(customer_note_value, ''),
    'HELD', price_value, NOW()
  );

  PERFORM public.append_audit_event(
    'PURCHASE_STORE_ACCOUNT', 'store_order', order_id_value::TEXT, NULL,
    jsonb_build_object('account_id', account_id_value, 'price', price_value, 'balance', next_balance),
    price_value, order_id_value
  );

  RETURN order_id_value;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_store_order(order_id_value UUID, reason_value TEXT DEFAULT NULL)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE item public.store_orders%ROWTYPE; next_balance NUMERIC; note TEXT;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;

  SELECT * INTO item FROM public.store_orders WHERE id = order_id_value FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'store order not found'; END IF;
  IF item.user_id <> auth.uid() AND NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF item.status NOT IN ('NEW', 'UNDER_REVIEW') THEN RAISE EXCEPTION 'order can no longer be cancelled'; END IF;

  note := COALESCE(NULLIF(reason_value, ''), 'إلغاء طلب شراء حساب من المتجر');

  IF item.escrow_status = 'HELD' AND COALESCE(item.escrow_amount, item.price) > 0 THEN
    next_balance := public.wallet_escrow_refund(
      item.user_id, COALESCE(item.escrow_amount, item.price), 'STORE_REFUND', 'store_order',
      item.id, 'store_order:refund:' || item.id, note
    );
  ELSE
    SELECT balance INTO next_balance FROM public.users WHERE id = item.user_id;
  END IF;

  UPDATE public.store_orders
     SET status = 'CANCELLED',
         escrow_status = CASE WHEN escrow_status = 'HELD' THEN 'REFUNDED' ELSE escrow_status END,
         refunded_at = CASE WHEN escrow_status = 'HELD' THEN NOW() ELSE refunded_at END,
         cancelled_by = auth.uid(),
         cancelled_at = NOW(),
         admin_note = note,
         updated_at = NOW()
   WHERE id = item.id;

  RETURN next_balance;
END;
$function$;

-- Admin delivery keeps the escrow as platform revenue; rejection refunds it.
CREATE OR REPLACE FUNCTION public.admin_resolve_store_order(
  store_order_id UUID,
  status_value TEXT,
  admin_note_value TEXT DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE item public.store_orders%ROWTYPE; next_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;
  IF status_value NOT IN ('NEW', 'UNDER_REVIEW', 'DELIVERED', 'CANCELLED') THEN RAISE EXCEPTION 'invalid status'; END IF;

  SELECT * INTO item FROM public.store_orders WHERE id = store_order_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'store order not found'; END IF;

  IF status_value = 'CANCELLED' THEN
    IF item.status = 'CANCELLED' THEN
      SELECT balance INTO next_balance FROM public.users WHERE id = item.user_id;
      RETURN next_balance;
    END IF;
    IF item.escrow_status = 'HELD' AND COALESCE(item.escrow_amount, item.price) > 0 THEN
      next_balance := public.wallet_escrow_refund(
        item.user_id, COALESCE(item.escrow_amount, item.price), 'STORE_REFUND', 'store_order',
        item.id, 'store_order:refund:' || item.id, COALESCE(NULLIF(admin_note_value, ''), 'رفضت الإدارة طلب شراء الحساب')
      );
    ELSE
      SELECT balance INTO next_balance FROM public.users WHERE id = item.user_id;
    END IF;

    UPDATE public.store_orders
       SET status = 'CANCELLED', admin_note = COALESCE(admin_note_value, ''),
           escrow_status = CASE WHEN escrow_status = 'HELD' THEN 'REFUNDED' ELSE escrow_status END,
           refunded_at = CASE WHEN escrow_status = 'HELD' THEN NOW() ELSE refunded_at END,
           cancelled_by = auth.uid(), cancelled_at = NOW(), reviewed_at = NOW(), updated_at = NOW()
     WHERE id = item.id;
    RETURN next_balance;
  END IF;

  IF status_value = 'DELIVERED' THEN
    UPDATE public.store_orders
       SET status = 'DELIVERED', admin_note = COALESCE(admin_note_value, ''),
           escrow_status = CASE WHEN escrow_status = 'HELD' THEN 'RELEASED' ELSE escrow_status END,
           delivered_at = NOW(), reviewed_at = NOW(), updated_at = NOW()
     WHERE id = item.id;
  ELSE
    UPDATE public.store_orders
       SET status = status_value, admin_note = COALESCE(admin_note_value, ''), reviewed_at = NOW(), updated_at = NOW()
     WHERE id = item.id;
  END IF;

  SELECT balance INTO next_balance FROM public.users WHERE id = item.user_id;
  RETURN next_balance;
END;
$function$;

-- Keep the legacy admin updater working but route money-bearing transitions through the new one.
-- The existing signature carries a parameter default, so replace it explicitly.
DROP FUNCTION IF EXISTS public.admin_update_store_order(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_update_store_order(
  store_order_id UUID,
  status_value TEXT,
  admin_note_value TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.admin_resolve_store_order(store_order_id, status_value, admin_note_value);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Coin recharge: escrow on request, refund on cancel/reject
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purchase_coin_recharge(
  recharge_id_value UUID,
  amount_value NUMERIC,
  method_value TEXT,
  whatsapp_value TEXT,
  notes_value TEXT
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE caller public.users%ROWTYPE; next_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
  IF recharge_id_value IS NULL OR amount_value IS NULL OR amount_value <= 0 THEN
    RAISE EXCEPTION 'invalid recharge request';
  END IF;

  SELECT * INTO caller FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF caller.id IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  IF caller.banned THEN RAISE EXCEPTION 'account is banned'; END IF;
  IF caller.balance < amount_value THEN RAISE EXCEPTION 'insufficient balance'; END IF;

  next_balance := public.wallet_escrow_hold(
    auth.uid(), amount_value, 'STORE_ESCROW', 'recharge', recharge_id_value,
    'recharge:hold:' || recharge_id_value, 'حجز مبلغ طلب شحن الكوينز'
  );

  INSERT INTO public.recharges (
    id, user_id, username, amount, payment_method, whatsapp, notes, status,
    escrow_status, escrow_amount, escrowed_at
  ) VALUES (
    recharge_id_value, auth.uid(), caller.username, amount_value,
    method_value, COALESCE(whatsapp_value, ''), COALESCE(notes_value, ''), 'PENDING',
    'HELD', amount_value, NOW()
  );

  PERFORM public.append_audit_event(
    'PURCHASE_COIN_RECHARGE', 'recharge', recharge_id_value::TEXT, NULL,
    jsonb_build_object('amount', amount_value, 'method', method_value, 'balance', next_balance),
    amount_value, recharge_id_value
  );

  RETURN next_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_coin_recharge(recharge_id_value UUID, reason_value TEXT DEFAULT NULL)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE item public.recharges%ROWTYPE; next_balance NUMERIC; note TEXT;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;

  SELECT * INTO item FROM public.recharges WHERE id = recharge_id_value FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'recharge not found'; END IF;
  IF item.user_id <> auth.uid() AND NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF item.status <> 'PENDING' THEN RAISE EXCEPTION 'request can no longer be cancelled'; END IF;

  note := COALESCE(NULLIF(reason_value, ''), 'إلغاء طلب شحن الكوينز');

  IF item.escrow_status = 'HELD' AND COALESCE(item.escrow_amount, item.amount) > 0 THEN
    next_balance := public.wallet_escrow_refund(
      item.user_id, COALESCE(item.escrow_amount, item.amount), 'STORE_REFUND', 'recharge',
      item.id, 'recharge:refund:' || item.id, note
    );
  ELSE
    SELECT balance INTO next_balance FROM public.users WHERE id = item.user_id;
  END IF;

  UPDATE public.recharges
     SET status = 'REJECTED',
         escrow_status = CASE WHEN escrow_status = 'HELD' THEN 'REFUNDED' ELSE escrow_status END,
         refunded_at = CASE WHEN escrow_status = 'HELD' THEN NOW() ELSE refunded_at END,
         cancelled_by = auth.uid(),
         updated_at = NOW()
   WHERE id = item.id;

  RETURN next_balance;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. review_recharge honours escrow: approve releases, reject refunds
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.review_recharge(recharge_id UUID, approve BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE item public.recharges%ROWTYPE; next_balance NUMERIC;
BEGIN
  PERFORM set_config('app.trusted_rpc', '1', true);
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin access required'; END IF;

  SELECT * INTO item FROM public.recharges WHERE id = recharge_id FOR UPDATE;
  IF item.id IS NULL OR item.status <> 'PENDING' THEN RAISE EXCEPTION 'request is not pending'; END IF;

  IF approve THEN
    -- Wallet-funded requests already moved the money at request time (escrow); approving
    -- only releases the hold. Legacy off-platform requests credit the wallet as before.
    IF item.escrow_status = 'HELD' THEN
      UPDATE public.recharges
         SET status = 'APPROVED', escrow_status = 'RELEASED', updated_at = NOW()
       WHERE id = recharge_id;
    ELSE
      UPDATE public.users SET balance = balance + item.amount, updated_at = NOW()
       WHERE id = item.user_id
      RETURNING balance INTO next_balance;
      UPDATE public.recharges
         SET status = 'APPROVED', updated_at = NOW()
       WHERE id = recharge_id;
      INSERT INTO public.transactions (user_id, type, description, amount, balance_after)
      VALUES (item.user_id, 'RECHARGE', 'اعتماد طلب الشحن', item.amount, next_balance);
    END IF;
  ELSE
    IF item.escrow_status = 'HELD' AND COALESCE(item.escrow_amount, item.amount) > 0 THEN
      next_balance := public.wallet_escrow_refund(
        item.user_id, COALESCE(item.escrow_amount, item.amount), 'STORE_REFUND', 'recharge',
        item.id, 'recharge:refund:' || item.id, 'رفضت الإدارة طلب شحن الكوينز'
      );
    END IF;
    UPDATE public.recharges
       SET status = 'REJECTED',
           escrow_status = CASE WHEN escrow_status = 'HELD' THEN 'REFUNDED' ELSE escrow_status END,
           refunded_at = CASE WHEN escrow_status = 'HELD' THEN NOW() ELSE refunded_at END,
           cancelled_by = auth.uid(), updated_at = NOW()
     WHERE id = recharge_id;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Grants (functions are security definer; keep them signed-in only)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.wallet_escrow_hold(UUID, NUMERIC, TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.wallet_escrow_refund(UUID, NUMERIC, TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purchase_store_account(UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_store_order(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purchase_coin_recharge(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_coin_recharge(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_store_order(UUID, TEXT, TEXT) TO authenticated;
