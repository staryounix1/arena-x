import { supabase } from './supabase';

type CheckoutRequest = { referenceType: 'RECHARGE' | 'COIN_RECHARGE' | 'STORE_ORDER'; referenceId: string; amount: number; description: string };

export const startPaymentCheckout = async (request: CheckoutRequest) => {
  if (!supabase) return { checkoutUrl: '', error: 'الدفع الإلكتروني غير مفعّل في هذه النسخة.' };
  const session = await supabase.auth.getSession();
  const token = session.data.session?.access_token;
  if (!token) return { checkoutUrl: '', error: 'سجّل الدخول قبل بدء الدفع.' };
  const response = await fetch('/api/payment/checkout', { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(request) });
  const payload = await response.json().catch(() => ({})) as { checkoutUrl?: string; error?: string };
  if (!response.ok || !payload.checkoutUrl) return { checkoutUrl: '', error: payload.error || 'تعذر بدء عملية الدفع.' };
  return { checkoutUrl: payload.checkoutUrl, error: '' };
};
