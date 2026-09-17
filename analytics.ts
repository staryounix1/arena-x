import { supabase, supabaseEnabled } from './supabase';

const sessionKey = 'arenax_analytics_session';

const sessionId = () => {
  try {
    const existing = sessionStorage.getItem(sessionKey);
    if (existing) return existing;
    const created = crypto.randomUUID();
    sessionStorage.setItem(sessionKey, created);
    return created;
  } catch {
    return undefined;
  }
};

export const recordAnalyticsEvent = (eventName: string, properties: Record<string, unknown> = {}) => {
  if (!supabaseEnabled || !supabase) return;
  void supabase.rpc('record_analytics_event', {
    event_name_value: eventName,
    route_value: window.location.pathname,
    properties_value: properties,
    session_id_value: sessionId(),
  });
};
