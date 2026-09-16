import { supabase, supabaseEnabled } from './supabase';

export type WhatsAppEvent =
  | { type: 'recharge'; id: string }
  | { type: 'withdrawal'; id: string }
  | { type: 'match_room'; id: string }
  | { type: 'match_claim'; id: string };

export const DEFAULT_ADMIN_WHATSAPP_LINK = 'https://wa.me/212604084574';

export type WhatsAppDeliveryConfig = {
  mode?: string;
  link?: string;
};

const eventLabel: Record<WhatsAppEvent['type'], string> = {
  recharge: 'طلب شحن جديد',
  withdrawal: 'طلب سحب جديد',
  match_room: 'تحديث غرفة مباراة',
  match_claim: 'تصريح نتيجة مباراة',
};

const normalizeLink = (value: string) => {
  const input = (value || '').trim();
  if (!input) return DEFAULT_ADMIN_WHATSAPP_LINK;
  if (/^\+?\d[\d\s-]+$/.test(input)) return `https://wa.me/${input.replace(/\D/g, '')}`;
  return input;
};

const openDirectLink = (event: WhatsAppEvent, link: string) => {
  if (typeof window === 'undefined') return;
  const base = normalizeLink(link);
  const separator = base.includes('?') ? '&' : '?';
  const text = `مرحباً، ${eventLabel[event.type]} في ARENA//X. المرجع: ${event.id}`;
  const href = `${base}${separator}text=${encodeURIComponent(text)}`;
  const opened = window.open(href, '_blank', 'noopener,noreferrer');
  if (!opened) window.location.assign(href);
};

export async function notifyWhatsApp(event: WhatsAppEvent, config: WhatsAppDeliveryConfig = {}): Promise<void> {
  const mode = config.mode || 'link';
  if (mode === 'link') {
    openDirectLink(event, config.link || DEFAULT_ADMIN_WHATSAPP_LINK);
    return;
  }
  if (mode !== 'meta' || !supabaseEnabled || !supabase) return;
  const session = (await supabase.auth.getSession()).data.session;
  if (!session?.access_token) return;

  try {
    await fetch('/api/whatsapp', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(event),
    });
  } catch (error) {
    console.error('WhatsApp notification failed', error);
  }
}
