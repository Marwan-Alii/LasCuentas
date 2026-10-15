import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

/** Service-role client. The key lives only in Edge Function secrets. */
export const admin = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

/** The scheduler authenticates with a shared secret so random callers cannot trigger runs. */
export function authorised(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}
