import { supabase, supabaseEnabled } from './supabase';

export type WhatsAppEvent =
  | { type: 'recharge'; id: string }
  | { type: 'withdrawal'; id: string }
  | { type: 'match_room'; id: string }
  | { type: 'match_claim'; id: string };

export async function notifyWhatsApp(event: WhatsAppEvent): Promise<void> {
  if (!supabaseEnabled || !supabase) return;
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
