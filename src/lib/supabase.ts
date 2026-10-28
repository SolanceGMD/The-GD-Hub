import { createClient } from '@supabase/supabase-js';

// The publishable key is intended for browser use. Database access remains
// protected by Supabase Auth, RLS policies, and the WCL review RPCs.
const url = (import.meta.env.VITE_SUPABASE_URL as string | undefined) || 'https://xvdinlyertutpddeilvq.supabase.co';
const key = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined) || 'sb_publishable_J0xpFgrZCYfTFY15AsHAFA_QYjZzyMB';
export const supabaseConfigured = Boolean(url && key && !url.includes('your-project'));
export const supabase = supabaseConfigured ? createClient(url, key) : null;
