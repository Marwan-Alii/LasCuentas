// Called every few minutes by pg_cron (see supabase/cron.sql). Safe to call concurrently or repeatedly:
// claim_due_reminders() re-checks eligibility in the database and can hand each reminder out only once.
import { admin, authorised } from "../_shared/auth.ts";
import { emailConfigured, sendEmail } from "../_shared/email.ts";

Deno.serve(async (req) => {
  if (!authorised(req)) return new Response("unauthorised", { status: 401 });
  const db = admin();
  const emailOn = emailConfigured();
  const { data, error } = await db.rpc("claim_due_reminders", { p_limit: 100, p_email_enabled: emailOn });
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  let sent = 0, failed = 0;
  for (const r of data ?? []) {
    const amount = `Rs. ${(Number(r.amount_minor) / 100).toLocaleString("en-PK", { maximumFractionDigits: 2 })}`;
    const out = await sendEmail(
      r.recipient,
      `Reminder: ${r.expense_title}`,
      `Hi ${String(r.debtor_name).split(" ")[0]}, your remaining share for ${r.expense_title} is ${amount}, owed to ${r.creditor_name}. Please send it when convenient.`,
    );
    await db.rpc("mark_reminder_attempt", { p_attempt: r.attempt_id, p_status: out.ok ? "sent" : "failed", p_error: out.error ?? null });
    out.ok ? sent++ : failed++;
  }
  return Response.json({ claimed: data?.length ?? 0, emailsSent: sent, emailsFailed: failed, emailConfigured: emailOn });
});
