import { createHmac, timingSafeEqual } from 'node:crypto';
import { json, supabaseAdmin } from '../_lib/supabase-admin';

export const config = { api: { bodyParser: false } };

const rawBody = async (request: any) => {
  if (typeof request.body === 'string') return request.body;
  if (Buffer.isBuffer(request.body)) return request.body.toString('utf8');
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf8');
};

const verified = (payload: string, signature: string, secret: string) => {
  const timestamp = signature.match(/t=(\d+)/)?.[1];
  const expected = signature.match(/v1=([a-f0-9]+)/)?.[1];
  if (!timestamp || !expected || Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;
  const digest = createHmac('sha256', secret).update(`${timestamp}.${payload}`).digest('hex');
  return digest.length === expected.length && timingSafeEqual(Buffer.from(digest), Buffer.from(expected));
};

export default async function handler(request: any, response: any) {
  if (request.method !== 'POST') return json(response, 405, { error: 'Method not allowed' });
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  const admin = supabaseAdmin();
  if (!secret || !admin) return json(response, 503, { error: 'Payment webhook is not configured yet' });
  const payload = await rawBody(request);
  if (!verified(payload, String(request.headers['stripe-signature'] || ''), secret)) return json(response, 400, { error: 'Invalid webhook signature' });
  const event = JSON.parse(payload) as { type?: string; data?: { object?: Record<string, any> } };
  if (!['checkout.session.completed', 'checkout.session.expired', 'checkout.session.async_payment_failed'].includes(event.type || '')) return json(response, 200, { received: true });
  const session = event.data?.object || {};
  const transactionId = String(session.metadata?.transaction_id || '');
  if (!transactionId) return json(response, 200, { received: true });
  const status = event.type === 'checkout.session.completed' ? 'PAID' : event.type === 'checkout.session.expired' ? 'EXPIRED' : 'FAILED';
  const transaction = await admin.from('payment_transactions').update({ status, paid_at: status === 'PAID' ? new Date().toISOString() : null, updated_at: new Date().toISOString(), metadata: { stripe_event: event.type } }).eq('id', transactionId).select('reference_type,reference_id').single();
  if (transaction.error || !transaction.data) return json(response, 404, { error: 'Payment transaction not found' });
  const table = transaction.data.reference_type === 'STORE_ORDER' ? 'store_orders' : 'recharges';
  await admin.from(table).update({ payment_status: status === 'PAID' ? 'PAID' : 'FAILED', payment_transaction_id: transactionId }).eq('id', transaction.data.reference_id);
  return json(response, 200, { received: true });
}
