// Single-file version for pasting into the Supabase dashboard editor.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

/** Service-role client. The key lives only in Edge Function secrets. */
export const admin = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

/** The scheduler authenticates with a shared secret so random callers cannot trigger runs. */
export function authorised(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}
// Email provider boundary. Secrets come from Edge Function secrets, never from the app.
// EMAIL_PROVIDER=brevo  -> BREVO_API_KEY, EMAIL_FROM (a sender you verified in Brevo)
// EMAIL_PROVIDER=resend -> RESEND_API_KEY, EMAIL_FROM
// With nothing configured, emailConfigured() is false and callers DO NOT claim email work,
// so nothing is ever recorded as "sent" that was not.

export function emailConfigured(): boolean {
  const p = Deno.env.get("EMAIL_PROVIDER");
  if (!Deno.env.get("EMAIL_FROM")) return false;
  if (p === "brevo") return !!Deno.env.get("BREVO_API_KEY");
  if (p === "resend") return !!Deno.env.get("RESEND_API_KEY");
  return false;
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

export function render(title: string, body: string): { subject: string; html: string; text: string } {
  const appLink = Deno.env.get("APP_LINK") ?? "";
  const html = `<div style="font-family:system-ui,sans-serif;max-width:480px;margin:auto;color:#172B27">
    <h2 style="margin:0 0 12px">${esc(title)}</h2><p style="font-size:16px;line-height:1.5">${esc(body)}</p>
    ${appLink ? `<p><a href="${esc(appLink)}" style="color:#172B27">Open Hisab</a></p>` : ""}
    <p style="color:#6b7a75;font-size:12px">Hisab only records payments; it never moves money. You can turn these emails off in Profile → Notifications.</p></div>`;
  return { subject: title, html, text: `${title}\n\n${body}` };
}

export async function sendEmail(to: string, title: string, body: string): Promise<{ ok: boolean; error?: string }> {
  const provider = Deno.env.get("EMAIL_PROVIDER");
  const from = Deno.env.get("EMAIL_FROM")!;
  const m = render(title, body);
  try {
    let res: Response;
    if (provider === "brevo") {
      res = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: { "api-key": Deno.env.get("BREVO_API_KEY")!, "content-type": "application/json" },
        body: JSON.stringify({ sender: { email: from, name: "Hisab" }, to: [{ email: to }], subject: m.subject, htmlContent: m.html, textContent: m.text }),
      });
    } else if (provider === "resend") {
      res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "content-type": "application/json" },
        body: JSON.stringify({ from, to: [to], subject: m.subject, html: m.html, text: m.text }),
      });
    } else return { ok: false, error: "email provider not configured" };
    if (!res.ok) return { ok: false, error: `provider ${res.status}: ${(await res.text()).slice(0, 200)}` };
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e).slice(0, 200) };
  }
}
// Emails for non-reminder events (payment reported / confirmed / disputed, new debt, ...).

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
