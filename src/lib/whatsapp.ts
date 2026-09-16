export type WhatsAppEvent =
  | { type: 'recharge'; id: string }
  | { type: 'withdrawal'; id: string }
  | { type: 'match_room'; id: string }
  | { type: 'match_claim'; id: string };

export const DEFAULT_ADMIN_WHATSAPP_LINK = 'https://wa.me/212604084574';

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

export function notifyWhatsApp(event: WhatsAppEvent, link = DEFAULT_ADMIN_WHATSAPP_LINK): void {
  if (typeof window === 'undefined') return;
  const base = normalizeLink(link);
  const separator = base.includes('?') ? '&' : '?';
  const text = `مرحباً، ${eventLabel[event.type]} في ARENA//X. المرجع: ${event.id}`;
  const href = `${base}${separator}text=${encodeURIComponent(text)}`;
  const opened = window.open(href, '_blank', 'noopener,noreferrer');
  if (!opened) window.location.assign(href);
}
