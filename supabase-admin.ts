import { createClient } from '@supabase/supabase-js';

export const supabaseAdmin = () => {
  const url = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false } });
};

export const json = (response: any, status: number, body: Record<string, unknown>) => response.status(status).json(body);
