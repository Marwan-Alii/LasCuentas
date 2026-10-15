// Emails for non-reminder events (payment reported / confirmed / disputed, new debt, ...).
import { admin, authorised } from "../_shared/auth.ts";
import { emailConfigured, sendEmail } from "../_shared/email.ts";

Deno.serve(async (req) => {
  if (!authorised(req)) return new Response("unauthorised", { status: 401 });
  const db = admin();
  const emailOn = emailConfigured();
  const { data, error } = await db.rpc("claim_email_notifications", { p_limit: 50, p_email_enabled: emailOn });
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  let sent = 0, failed = 0, skipped = 0;
  for (const n of data ?? []) {
    if (!n.recipient) { await db.rpc("mark_notification_email", { p_id: n.notification_id, p_status: "skipped" }); skipped++; continue; }
    const out = await sendEmail(n.recipient, n.title, n.body);
    await db.rpc("mark_notification_email", { p_id: n.notification_id, p_status: out.ok ? "sent" : "failed" });
    out.ok ? sent++ : failed++;
  }
  return Response.json({ claimed: data?.length ?? 0, sent, failed, skipped, emailConfigured: emailOn });
});
