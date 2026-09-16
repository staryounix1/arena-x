import { createClient } from '@supabase/supabase-js';

type EventType = 'recharge' | 'withdrawal' | 'match_room' | 'match_claim';
type RequestBody = { type?: EventType; id?: string };

const json = (response: any, status: number, body: Record<string, unknown>) => response.status(status).json(body);
const money = (value: unknown) => `$${Number(value || 0).toFixed(2)}`;
const safe = (value: unknown, fallback = 'غير متوفر') => String(value || fallback);

const recipientFromLink = (value: string) => value.match(/wa\.me\/(\d+)/i)?.[1] || '';

export default async function handler(request: any, response: any) {
  if (request.method !== 'POST') return json(response, 405, { error: 'Method not allowed' });
  const body = (request.body || {}) as RequestBody;
  if (!body.type || !body.id) return json(response, 400, { error: 'Missing notification data' });

  const supabaseUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const accessToken = String(request.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!supabaseUrl || !serviceRoleKey || !accessToken) return json(response, 503, { error: 'Meta API is not configured' });

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const auth = await admin.auth.getUser(accessToken);
  if (auth.error || !auth.data.user) return json(response, 401, { error: 'Unauthorized' });
  const callerId = auth.data.user.id;
  const caller = await admin.from('users').select('id,role').eq('id', callerId).maybeSingle();
  if (caller.error || !caller.data) return json(response, 403, { error: 'Profile not found' });
  const isAdmin = caller.data.role === 'ADMIN';

  const secret = await admin.from('whatsapp_secrets').select('access_token,phone_number_id').eq('id', true).maybeSingle();
  if (secret.error || !secret.data) return json(response, 503, { error: 'Meta API credentials are not configured' });
  const directLink = await admin.from('settings').select('value').eq('key', 'whatsapp_direct_link').maybeSingle();
  const recipient = recipientFromLink(String(directLink.data?.value || ''));
  if (!recipient) return json(response, 503, { error: 'Admin WhatsApp number is not configured' });

  let eventKey = `${body.type}:${body.id}`;
  let message = '';
  if (body.type === 'recharge' || body.type === 'withdrawal') {
    const table = body.type === 'recharge' ? 'recharges' : 'withdrawals';
    const result = await admin.from(table).select('*').eq('id', body.id).maybeSingle();
    if (result.error || !result.data) return json(response, 404, { error: 'Request not found' });
    if (!isAdmin && result.data.user_id !== callerId) return json(response, 403, { error: 'Forbidden' });
    const profile = await admin.from('users').select('username,email,efootball_id').eq('id', result.data.user_id).single();
    if (profile.error || !profile.data) return json(response, 404, { error: 'User not found' });
     const kind = body.type === 'recharge' ? 'طلب شحن' : 'طلب سحب';
    const method = body.type === 'recharge' ? result.data.payment_method : result.data.method;
    const destination = body.type === 'recharge' ? result.data.whatsapp : result.data.destination;
     message = [`النوع: ${kind}`, `الحساب: ${profile.data.efootball_id}`, `اسم المستخدم: ${profile.data.username}`, `المبلغ: ${money(result.data.amount)}`, `الطريقة: ${method}`, `مرجع الطلب: ${result.data.id}`, `بيانات التحويل: ${destination}`, `الحالة: ${result.data.status}`, `ملاحظات: ${safe(result.data.notes, 'لا توجد')}`].join('\n');
  }

  if (body.type === 'match_room' || body.type === 'match_claim') {
    const matchResult = await admin.from('matches').select('*').eq('id', body.id).maybeSingle();
    if (matchResult.error || !matchResult.data) return json(response, 404, { error: 'Match not found' });
    const match = matchResult.data;
    const participants = [match.creator_id, match.opponent_id].filter(Boolean);
    if (!isAdmin && !participants.includes(callerId)) return json(response, 403, { error: 'Forbidden' });
    const profiles = await admin.from('users').select('id,username,email,efootball_id').in('id', participants);
    if (profiles.error) return json(response, 500, { error: 'Could not load match users' });
    const byId = new Map((profiles.data || []).map((item: any) => [item.id, item]));
    const creator = byId.get(match.creator_id) || { username: match.creator_name, email: '', efootball_id: match.creator_efootball_id };
    const opponent = match.opponent_id ? byId.get(match.opponent_id) || { username: match.opponent_name, email: '', efootball_id: match.opponent_efootball_id } : null;
    const playerLine = (label: string, player: any) => `${label}: ${safe(player?.username)} | ${safe(player?.email)} | ${safe(player?.efootball_id)}`;
    const claimLabel = (claim: string | null, player: any) => claim ? claim === player?.id ? `فاز ${safe(player?.username)}` : claim === opponent?.id ? `فاز ${safe(opponent?.username)}` : safe(claim) : 'لم يرسل بعد';
    eventKey = `${body.type}:${body.id}:${body.type === 'match_claim' ? `${match.creator_claim || ''}:${match.opponent_claim || ''}` : match.room_code || ''}`;
     message = body.type === 'match_room'
       ? [`النوع: مباراة جديدة`, `الحالة: جارية`, `أيدي الحساب 1: ${safe(creator?.efootball_id)}`, `أيدي الحساب 2: ${safe(opponent?.efootball_id)}`, `مبلغ المباراة: ${money(match.stake)}`, `أيدي المباراة: ${match.id}`].join('\n')
       : [`النوع: تصريح نتيجة مباراة`, `أيدي المباراة: ${match.id}`, playerLine('اللاعب 1', creator), playerLine('اللاعب 2', opponent), `الرهان: ${money(match.stake)}`, `الجائزة: ${money(match.prize)}`, `تصريح اللاعب 1: ${claimLabel(match.creator_claim, creator)}`, `تصريح اللاعب 2: ${claimLabel(match.opponent_claim, opponent)}`, `الحالة: ${match.status}`].join('\n');
  }

  const existing = await admin.from('whatsapp_notifications').select('id').eq('event_key', eventKey).maybeSingle();
  if (existing.data) return json(response, 200, { ok: true, duplicate: true });
  const sent = await fetch(`https://graph.facebook.com/v20.0/${secret.data.phone_number_id}/messages`, { method: 'POST', headers: { Authorization: `Bearer ${secret.data.access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ messaging_product: 'whatsapp', to: recipient, type: 'text', text: { preview_url: false, body: message } }) });
  if (!sent.ok) return json(response, 502, { error: 'Meta rejected the message' });
  await admin.from('whatsapp_notifications').insert({ event_key: eventKey, event_type: body.type, reference_id: body.id });
  return json(response, 200, { ok: true });
}
