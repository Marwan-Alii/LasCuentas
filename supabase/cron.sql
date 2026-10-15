-- Run ONCE in the Supabase SQL editor after deploying the Edge Functions.
-- pg_cron + pg_net are included in Supabase projects; no external scheduler or credit card is needed.
-- 1. Enable the extensions (Dashboard -> Database -> Extensions) or:
create extension if not exists pg_cron;
create extension if not exists pg_net;
-- 2. Store the secrets in Vault (replace the placeholders; use the same CRON_SECRET you set on the functions):
select vault.create_secret('https://YOUR-PROJECT-REF.supabase.co/functions/v1', 'hisab_functions_url');
select vault.create_secret('REPLACE_WITH_LONG_RANDOM_CRON_SECRET', 'hisab_cron_secret');
-- 3. Schedule. Reminder intervals are >= 3 hours, so a 10-minute tick is plenty precise.
select cron.schedule('hisab-process-reminders', '*/10 * * * *', $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'hisab_functions_url') || '/process-reminders',
    headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hisab_cron_secret'),
                                  'content-type', 'application/json'),
    body    := '{}'::jsonb) $$);
select cron.schedule('hisab-send-notifications', '*/5 * * * *', $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'hisab_functions_url') || '/send-notifications',
    headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hisab_cron_secret'),
                                  'content-type', 'application/json'),
    body    := '{}'::jsonb) $$);
-- Edge Functions must be deployed with --no-verify-jwt (they authenticate with x-cron-secret instead).
