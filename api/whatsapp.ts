import { createClient } from '@supabase/supabase-js';

type EventType = 'recharge' | 'withdrawal' | 'match_room' | 'match_claim';
type RequestBody = { type?: EventType; id?: string };

const json = (response: any, status: number, body: Record<string, unknown>) => response.status(status).json(body);

const money = (value: unknown) => `$${Number(value || 0).toFixed(2)}`;
const phone = (value: string) => value.replace(/\D/g, '');
const safe = (value: unknown, fallback = 'غير متوفر') => String(value || fallback);

export default async function handler(request: any, response: any) {
  if (request.method !== 'POST') return json(response, 405, { error: 'Method not allowed' });

  const body = (request.body || {}) as RequestBody;
  if (!body.type || !body.id) return json(response, 400, { error: 'Missing notification data' });

  const supabaseUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const accessToken = String(request.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const whatsappToken = process.env.WHATSAPP_ACCESS_TOKEN;
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;

  if (!supabaseUrl || !serviceRoleKey || !accessToken || !whatsappToken || !phoneNumberId) {
    return json(response, 503, { error: 'WhatsApp integration is not configured' });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const auth = await admin.auth.getUser(accessToken);
  if (auth.error || !auth.data.user) return json(response, 401, { error: 'Unauthorized' });

  const callerId = auth.data.user.id;
  const caller = await admin.from('users').select('id,role').eq('id', callerId).maybeSingle();
  if (caller.error || !caller.data) return json(response, 403, { error: 'Profile not found' });
  const isAdmin = caller.data.role === 'ADMIN';

  const adminSetting = await admin.from('settings').select('value').eq('key', 'admin_whatsapp').maybeSingle();
  const recipient = phone(process.env.WHATSAPP_ADMIN_PHONE || String(adminSetting.data?.value || ''));
  if (!recipient) return json(response, 503, { error: 'Admin WhatsApp number is not configured' });

  let eventKey = `${body.type}:${body.id}`;
  let message = '';

  if (body.type === 'recharge' || body.type === 'withdrawal') {
    const table = body.type === 'recharge' ? 'recharges' : 'withdrawals';
    const result = await admin.from(table).select('*').eq('id', body.id).maybeSingle();
    if (result.error || !result.data) return json(response, 404, { error: 'Request not found' });
    if (!isAdmin && result.data.user_id !== callerId) return json(response, 403, { error: 'Forbidden' });
    const profile = await admin.from('users').select('username,email,efootball_id,whatsapp').eq('id', result.data.user_id).single();
    if (profile.error || !profile.data) return json(response, 404, { error: 'User not found' });

    const kind = body.type === 'recharge' ? 'شحن' : 'سحب';
    const method = body.type === 'recharge' ? result.data.payment_method : result.data.method;
    const destination = body.type === 'recharge' ? result.data.whatsapp : result.data.destination;
    message = [
      `🔔 طلب ${kind} جديد في ARENA//X`,
      `رقم الطلب: ${result.data.id}`,
      `المستخدم: ${profile.data.username}`,
      `البريد: ${profile.data.email}`,
      `eFootball ID: ${profile.data.efootball_id}`,
      `المبلغ: ${money(result.data.amount)}`,
      `الطريقة: ${method}`,
      `بيانات التحويل: ${destination}`,
      `الحالة: ${result.data.status}`,
      `ملاحظات: ${safe(result.data.notes, 'لا توجد')}`,
    ].join('\n');
  }

  if (body.type === 'match_room' || body.type === 'match_claim') {
    const matchResult = await admin.from('matches').select('*').eq('id', body.id).maybeSingle();
    if (matchResult.error || !matchResult.data) return json(response, 404, { error: 'Match not found' });
    const match = matchResult.data;
    const participants = [match.creator_id, match.opponent_id].filter(Boolean);
    if (!isAdmin && !participants.includes(callerId)) return json(response, 403, { error: 'Forbidden' });
    const profiles = await admin.from('users').select('id,username,email,efootball_id,whatsapp').in('id', participants);
    if (profiles.error) return json(response, 500, { error: 'Could not load match users' });
    const byId = new Map((profiles.data || []).map((item: any) => [item.id, item]));
    const creator = byId.get(match.creator_id) || { username: match.creator_name, email: '', efootball_id: match.creator_efootball_id };
    const opponent = match.opponent_id ? byId.get(match.opponent_id) || { username: match.opponent_name, email: '', efootball_id: match.opponent_efootball_id } : null;
    const playerLine = (label: string, player: any) => `${label}: ${safe(player?.username)} | ${safe(player?.email)} | ${safe(player?.efootball_id)}`;
    eventKey = `${body.type}:${body.id}:${body.type === 'match_claim' ? `${match.creator_claim || ''}:${match.opponent_claim || ''}` : match.room_code || ''}`;
    message = [
      body.type === 'match_room' ? '🎮 تحديث غرفة مباراة ARENA//X' : '🏁 تصريح نتيجة مباراة ARENA//X',
      `رقم المباراة: ${match.id}`,
      `العنوان: ${match.title}`,
      `المنصة: ${match.platform}`,
      `الرهان: ${money(match.stake)} | الجائزة: ${money(match.prize)}`,
      playerLine('اللاعب 1', creator),
      playerLine('اللاعب 2', opponent),
      `رمز الغرفة: ${safe(match.room_code)}`,
      `تصريح اللاعب 1: ${safe(match.creator_claim, 'لم يرسل بعد')}`,
      `تصريح اللاعب 2: ${safe(match.opponent_claim, 'لم يرسل بعد')}`,
      `الحالة: ${match.status}`,
    ].join('\n');
  }

  const existing = await admin.from('whatsapp_notifications').select('id').eq('event_key', eventKey).maybeSingle();
  if (existing.data) return json(response, 200, { ok: true, duplicate: true });

  const sent = await fetch(`https://graph.facebook.com/v20.0/${phoneNumberId}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${whatsappToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      to: recipient,
      type: 'text',
      text: { preview_url: false, body: message },
    }),
  });
  if (!sent.ok) return json(response, 502, { error: 'WhatsApp provider rejected the message' });

  await admin.from('whatsapp_notifications').insert({ event_key: eventKey, event_type: body.type, reference_id: body.id });
  return json(response, 200, { ok: true });
}
