import { createClient } from '@supabase/supabase-js';

const json = (response: any, status: number, body: Record<string, unknown>) => response.status(status).json(body);

const getAdmin = async (request: any) => {
  const supabaseUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const accessToken = String(request.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!supabaseUrl || !serviceRoleKey || !accessToken) return null;
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const auth = await admin.auth.getUser(accessToken);
  if (auth.error || !auth.data.user) return null;
  const profile = await admin.from('users').select('role').eq('id', auth.data.user.id).maybeSingle();
  if (profile.error || profile.data?.role !== 'ADMIN') return null;
  return admin;
};

export default async function handler(request: any, response: any) {
  const admin = await getAdmin(request);
  if (!admin) return json(response, 401, { error: 'Unauthorized' });

  if (request.method === 'GET') {
    const result = await admin.from('whatsapp_secrets').select('phone_number_id,updated_at').eq('id', true).maybeSingle();
    if (result.error) return json(response, 500, { error: 'Could not read WhatsApp configuration' });
    return json(response, 200, { configured: Boolean(result.data), phoneNumberId: result.data?.phone_number_id || '', updatedAt: result.data?.updated_at || null });
  }

  if (request.method !== 'POST') return json(response, 405, { error: 'Method not allowed' });
  const body = request.body || {};
  const accessToken = String(body.accessToken || '').trim();
  const phoneNumberId = String(body.phoneNumberId || '').trim();
  if (!accessToken || !phoneNumberId) return json(response, 400, { error: 'Access token and Phone Number ID are required' });

  const result = await admin.from('whatsapp_secrets').upsert({ id: true, access_token: accessToken, phone_number_id: phoneNumberId, updated_at: new Date().toISOString() });
  if (result.error) return json(response, 500, { error: 'Could not save WhatsApp configuration' });
  return json(response, 200, { ok: true, configured: true, phoneNumberId });
}
