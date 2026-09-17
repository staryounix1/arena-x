import { createClient } from '@supabase/supabase-js';
import { json, supabaseAdmin } from '../_lib/supabase-admin';

type PaymentBody = { referenceType?: 'RECHARGE' | 'COIN_RECHARGE' | 'STORE_ORDER'; referenceId?: string; amount?: number; currency?: string; description?: string; successUrl?: string; cancelUrl?: string };

const getCaller = async (request: any) => {
  const admin = supabaseAdmin();
  const token = String(request.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!admin || !token) return null;
  const auth = await admin.auth.getUser(token);
  if (auth.error || !auth.data.user) return null;
  return { admin, userId: auth.data.user.id };
};

export default async function handler(request: any, response: any) {
  if (request.method !== 'POST') return json(response, 405, { error: 'Method not allowed' });
  const caller = await getCaller(request);
  if (!caller) return json(response, 401, { error: 'Unauthorized' });
  const stripeKey = process.env.STRIPE_SECRET_KEY;
  if (!stripeKey) return json(response, 503, { error: 'Electronic payment is not configured yet' });
  const body = (request.body || {}) as PaymentBody;
  const amount = Number(body.amount || 0);
  if (!body.referenceType || !body.referenceId || !Number.isFinite(amount) || amount <= 0) return json(response, 400, { error: 'Invalid payment request' });

  const referenceTable = body.referenceType === 'STORE_ORDER' ? 'store_orders' : 'recharges';
  const referenceColumns = body.referenceType === 'STORE_ORDER' ? 'id,user_id,price' : 'id,user_id,amount';
  const reference = await caller.admin.from(referenceTable).select(referenceColumns).eq('id', body.referenceId).maybeSingle();
  if (reference.error || !reference.data || reference.data.user_id !== caller.userId) return json(response, 404, { error: 'Payment reference not found' });
  const expectedAmount = Number(reference.data.price ?? reference.data.amount ?? 0);
  if (Math.abs(expectedAmount - amount) > 0.01) return json(response, 400, { error: 'Payment amount does not match the order' });

  const transaction = await caller.admin.from('payment_transactions').insert({ user_id: caller.userId, provider: 'STRIPE', reference_type: body.referenceType, reference_id: body.referenceId, amount, currency: body.currency || 'usd', status: 'PENDING', metadata: { description: body.description || '' } }).select('id').single();
  if (transaction.error || !transaction.data) return json(response, 500, { error: 'Could not create payment transaction' });

  const params = new URLSearchParams();
  params.set('mode', 'payment');
  params.set('success_url', body.successUrl || `${request.headers.origin || ''}/orders?payment=success`);
  params.set('cancel_url', body.cancelUrl || `${request.headers.origin || ''}/store/recharge?payment=cancelled`);
  params.set('line_items[0][price_data][currency]', body.currency || 'usd');
  params.set('line_items[0][price_data][product_data][name]', body.description || 'ARENA//X payment');
  params.set('line_items[0][price_data][unit_amount]', String(Math.round(amount * 100)));
  params.set('line_items[0][quantity]', '1');
  params.set('metadata[transaction_id]', transaction.data.id);
  params.set('metadata[reference_type]', body.referenceType);
  params.set('metadata[reference_id]', body.referenceId);
  const checkout = await fetch('https://api.stripe.com/v1/checkout/sessions', { method: 'POST', headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' }, body: params });
  const payload = await checkout.json() as { id?: string; url?: string; error?: { message?: string } };
  if (!checkout.ok || !payload.id || !payload.url) { await caller.admin.from('payment_transactions').update({ status: 'FAILED', metadata: { error: payload.error?.message || 'Stripe checkout failed' } }).eq('id', transaction.data.id); return json(response, 502, { error: payload.error?.message || 'Payment provider rejected the request' }); }
  await caller.admin.from('payment_transactions').update({ provider_session_id: payload.id }).eq('id', transaction.data.id);
  return json(response, 200, { checkoutUrl: payload.url, transactionId: transaction.data.id });
}
