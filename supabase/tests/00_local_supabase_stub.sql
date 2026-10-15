-- LOCAL TESTING ONLY. Real Supabase projects already provide all of this. Never run on Supabase.
create schema if not exists auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text, phone text,
  email_confirmed_at timestamptz, phone_confirmed_at timestamptz,
  raw_user_meta_data jsonb not null default '{}'
);
create or replace function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
do $$ begin
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
exception when duplicate_object then null; end $$;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
