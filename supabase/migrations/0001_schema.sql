-- Hisab schema. All money is integer paisa (bigint). Financial tables are written only through
-- SECURITY DEFINER functions (0002); clients get SELECT through RLS (0003).

create type party_kind       as enum ('user', 'guest');
create type contact_kind     as enum ('email', 'whatsapp');
create type group_role       as enum ('owner', 'admin', 'member');
create type member_status    as enum ('active', 'left', 'removed');
create type expense_status   as enum ('active', 'voided');
create type repayment_status as enum ('reported', 'disputed', 'confirmed', 'rejected', 'reversed');

create function set_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;

-- ------------------------------------------------------------------ identity
create table profiles (
  id                   uuid primary key references auth.users (id) on delete restrict,
  display_name         text not null check (length(btrim(display_name)) between 1 and 80),
  avatar_url           text,
  email_discoverable   boolean not null default false,   -- others may find me by verified email
  phone_discoverable   boolean not null default false,   -- others may find me by verified WhatsApp
  email_notifications  boolean not null default true,
  inapp_notifications  boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create trigger trg_profiles_updated before update on profiles for each row execute function set_updated_at();

-- Only VERIFIED identifiers are stored here. One verified identifier belongs to exactly one profile.
create table profile_contacts (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profiles (id) on delete restrict,
  kind        contact_kind not null,
  value       text not null,
  verified_at timestamptz not null default now(),
  unique (kind, value)
);
create index on profile_contacts (profile_id);

-- A "party" is anyone who can take part in money: a registered user or a guest profile.
-- Financial rows reference parties, so claiming a guest never breaks history.
create table parties (
  id           uuid primary key default gen_random_uuid(),
  kind         party_kind not null,
  user_id      uuid unique references profiles (id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 1 and 80),
  email        text,                       -- guests only (contact details of users live in profile_contacts)
  whatsapp     text,
  notes        text,
  created_by   uuid references profiles (id) on delete restrict,
  claim_status text not null default 'n/a' check (claim_status in ('n/a', 'unclaimed', 'claimed')),
  merged_into  uuid references parties (id),
  created_at   timestamptz not null default now(),
  check ((kind = 'user') = (user_id is not null)),
  check (kind = 'user' or created_by is not null),
  check (kind = 'guest' or (email is null and whatsapp is null))
);
create index on parties (created_by);

create table profile_claims (
  id             uuid primary key default gen_random_uuid(),
  guest_party_id uuid not null references parties (id),
  claimant_id    uuid not null references profiles (id),
  matched_kind   contact_kind not null,
  matched_value  text not null,
  moved          jsonb not null,
  created_at     timestamptz not null default now(),
  unique (guest_party_id)                  -- a guest can be claimed only once
);

-- Parties a user has legitimately discovered (lookup) so they may be added to expenses.
create table known_parties (
  owner_id uuid not null references profiles (id) on delete cascade,
  party_id uuid not null references parties (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, party_id)
);

create table device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  token text not null unique,
  platform text not null default 'android',
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------------ payment methods
create table payment_methods (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references profiles (id) on delete cascade,
  provider            text not null check (length(btrim(provider)) > 0),  -- free text: no closed list
  method_type         text not null check (method_type in ('bank', 'wallet', 'other')),
  account_holder      text not null,
  account_number      text not null check (length(btrim(account_number)) > 0),
  nickname            text,
  instructions        text,
  is_default          boolean not null default false,
  shared_with_debtors boolean not null default false,   -- private by default
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index one_default_method on payment_methods (owner_id) where is_default;
create trigger trg_pm_updated before update on payment_methods for each row execute function set_updated_at();

-- ------------------------------------------------------------------ groups
create table groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 80),
  description text,
  avatar_url  text,
  owner_id    uuid not null references profiles (id) on delete restrict,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger trg_groups_updated before update on groups for each row execute function set_updated_at();

create table group_members (
  group_id  uuid not null references groups (id) on delete restrict,
  party_id  uuid not null references parties (id) on delete restrict,
  role      group_role not null default 'member',
  status    member_status not null default 'active',
  added_by  uuid references profiles (id),
  joined_at timestamptz not null default now(),
  left_at   timestamptz,
  primary key (group_id, party_id)
);
create index on group_members (party_id) where status = 'active';

create table group_invites (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups (id) on delete cascade,
  code_hash  bytea not null unique,        -- only the hash of the code is stored
  created_by uuid not null references profiles (id),
  expires_at timestamptz not null,
  max_uses   int not null default 10 check (max_uses between 1 and 100),
  uses       int not null default 0,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------------ expenses
create table expenses (
  id                  uuid primary key default gen_random_uuid(),
  created_by          uuid not null references profiles (id) on delete restrict,
  client_op_id        uuid not null,
  group_id            uuid references groups (id) on delete restrict,
  title               text not null check (length(btrim(title)) between 1 and 120),
  notes               text,
  category            text,
  expense_date        date not null default current_date,
  expense_time        time,
  currency            char(3) not null default 'PKR' check (currency = 'PKR'),
  total_minor         bigint not null check (total_minor >= 0),
  unpaid_minor        bigint not null check (unpaid_minor >= 0),
  status              expense_status not null default 'active',
  version             int not null default 1,
  receipt_path        text,
  reminder_interval_h int not null default 24 check (reminder_interval_h in (3, 6, 12, 24)),
  reminder_max        int not null default 5 check (reminder_max between 1 and 20),
  void_reason         text,
  voided_at           timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (created_by, client_op_id),       -- idempotent creation
  check (unpaid_minor <= total_minor)
);
create index on expenses (group_id, expense_date desc);
create index on expenses (created_by, created_at desc);
create trigger trg_exp_updated before update on expenses for each row execute function set_updated_at();

create table expense_items (
  id          uuid primary key default gen_random_uuid(),
  expense_id  uuid not null references expenses (id) on delete restrict,
  kind        text not null default 'item' check (kind in ('item', 'charge')),
  name        text not null,
  quantity    int not null check (quantity >= 1),
  unit_minor  bigint not null check (unit_minor >= 0),
  line_minor  bigint not null check (line_minor >= 0),
  method      text not null check (method in ('equal', 'custom', 'quantity', 'proportional')),
  category    text,
  notes       text,
  position    int not null default 0,
  check (line_minor = quantity::bigint * unit_minor)
);
create index on expense_items (expense_id);

create table item_allocations (
  item_id      uuid not null references expense_items (id) on delete restrict,
  party_id     uuid not null references parties (id) on delete restrict,
  amount_minor bigint not null check (amount_minor >= 0),
  units        int,
  primary key (item_id, party_id)
);

create table expense_shares (
  expense_id  uuid not null references expenses (id) on delete restrict,
  party_id    uuid not null references parties (id) on delete restrict,
  share_minor bigint not null check (share_minor >= 0),
  remind      boolean not null default true,   -- "Send reminders to this person"
  primary key (expense_id, party_id)
);
create index on expense_shares (party_id);

-- What each person actually paid toward the original bill. NOT a repayment.
create table contributions (
  id           uuid primary key default gen_random_uuid(),
  expense_id   uuid not null references expenses (id) on delete restrict,
  party_id     uuid not null references parties (id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  unique (expense_id, party_id)
);
create index on contributions (party_id);

-- Direct obligations derived from the expense by the server. Never edited by clients.
create table debts (
  id           uuid primary key default gen_random_uuid(),
  expense_id   uuid not null references expenses (id) on delete restrict,
  debtor_party uuid not null references parties (id) on delete restrict,
  creditor_party uuid not null references parties (id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  seq          bigint generated always as identity,    -- repayments apply oldest-first
  created_at   timestamptz not null default now(),
  unique (expense_id, debtor_party, creditor_party),
  check (debtor_party <> creditor_party)
);
create index on debts (debtor_party);
create index on debts (creditor_party);

-- ------------------------------------------------------------------ repayments
create table repayments (
  id              uuid primary key default gen_random_uuid(),
  idempotency_key text not null,
  created_by      uuid not null references profiles (id),
  from_party      uuid not null references parties (id),
  to_party        uuid not null references parties (id),
  reported_minor  bigint not null check (reported_minor > 0),
  confirmed_minor bigint not null default 0 check (confirmed_minor >= 0),
  status          repayment_status not null default 'reported',
  reference       text,
  note            text,
  reason          text,
  screenshot_path text,
  cash_recorded   boolean not null default false,
  confirmed_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (created_by, idempotency_key),
  check (from_party <> to_party),
  check (confirmed_minor <= reported_minor)
);
create index on repayments (from_party, to_party, status);
create index on repayments (to_party) where status in ('reported', 'disputed');
create trigger trg_rep_updated before update on repayments for each row execute function set_updated_at();

-- Append-only. A reversal inserts negative rows that point at the rows they cancel.
create table repayment_allocations (
  id           bigint generated always as identity primary key,
  repayment_id uuid not null references repayments (id),
  debt_id      uuid not null references debts (id),
  amount_minor bigint not null check (amount_minor <> 0),
  reverses     bigint references repayment_allocations (id),
  created_at   timestamptz not null default now()
);
create index on repayment_allocations (debt_id);
create index on repayment_allocations (repayment_id);

-- Append-only adjustments (e.g. creditor forgives part of a debt). Negative = reduces what is owed.
create table debt_adjustments (
  id          bigint generated always as identity primary key,
  debt_id     uuid not null references debts (id),
  delta_minor bigint not null check (delta_minor <> 0),
  reason      text not null check (length(btrim(reason)) > 0),
  actor_id    uuid not null references profiles (id),
  created_at  timestamptz not null default now()
);
create index on debt_adjustments (debt_id);

-- ------------------------------------------------------------------ notifications & reminders
create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles (id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text not null,
  data       jsonb not null default '{}',      -- deep-link target: {"expense_id": "...", "debt_id": "..."}
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index on notifications (user_id, created_at desc);
create index on notifications (user_id) where read_at is null;

create table reminder_schedules (
  debt_id        uuid primary key references debts (id) on delete cascade,
  interval_hours int not null check (interval_hours in (3, 6, 12, 24)),
  max_count      int not null check (max_count between 1 and 20),
  sent_count     int not null default 0,
  next_due_at    timestamptz not null,
  paused_until   timestamptz,
  updated_at     timestamptz not null default now()
);
create index on reminder_schedules (next_due_at);

create table reminder_attempts (
  id         uuid primary key default gen_random_uuid(),
  debt_id    uuid not null references debts (id) on delete cascade,
  sequence   int not null,
  channel    text not null check (channel in ('email', 'inapp')),
  status     text not null default 'claimed' check (status in ('claimed', 'sent', 'failed', 'skipped')),
  amount_minor bigint not null,
  recipient  text,
  error      text,
  created_at timestamptz not null default now(),
  unique (debt_id, sequence, channel)          -- the scheduler can never send the same reminder twice
);

-- ------------------------------------------------------------------ audit
create table activity_events (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  actor_id     uuid references profiles (id),     -- set from auth.uid() inside functions, never from input
  type         text not null,
  subject_type text not null,
  subject_id   uuid,
  expense_id   uuid references expenses (id),
  group_id     uuid references groups (id),
  before       jsonb,
  after        jsonb,
  reason       text,
  audience     uuid[] not null default '{}'       -- profile ids allowed to see this event
);
create index on activity_events using gin (audience);
create index on activity_events (expense_id);

create function forbid_change() returns trigger language plpgsql as
$$ begin raise exception '% is append-only', tg_table_name using errcode = '42501'; end $$;
create trigger activity_events_immutable before update or delete on activity_events for each row execute function forbid_change();
create trigger repayment_allocations_immutable before update or delete on repayment_allocations for each row execute function forbid_change();
create trigger debt_adjustments_immutable before update or delete on debt_adjustments for each row execute function forbid_change();
