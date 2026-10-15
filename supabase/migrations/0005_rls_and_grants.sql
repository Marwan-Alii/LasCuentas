-- Row Level Security + least-privilege grants.
-- Model: clients may only SELECT (through RLS) and call the audited RPC functions listed at the bottom.
-- There is no INSERT/UPDATE/DELETE grant on any financial, audit, claim or membership table.

-- ------------------------------------------------------------------ extra helpers used by policies
create function can_see_party(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select controls_party(p)
      or exists (select 1 from known_parties k where k.owner_id = auth.uid() and k.party_id = p)
      or exists (select 1 from group_members a join group_members b on a.group_id = b.group_id
                 where a.party_id = my_party() and a.status = 'active' and b.party_id = p)
      or exists (select 1 from expense_shares s where s.party_id = p and can_see_expense(s.expense_id))
      or exists (select 1 from contributions c where c.party_id = p and can_see_expense(c.expense_id))
      or exists (select 1 from repayments r where (r.from_party = p or r.to_party = p) and (controls_party(r.from_party) or controls_party(r.to_party))) $$;

create function can_see_debt(p uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from debts d where d.id = p and (controls_party(d.debtor_party) or controls_party(d.creditor_party))) $$;

create function can_see_repayment(p uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from repayments r where r.id = p and (controls_party(r.from_party) or controls_party(r.to_party))) $$;

-- Payment details are visible to their owner and, only if the owner chose to share, to people who currently owe them money.
create function owes_money_to(p_owner uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from debt_balances b join parties c on c.id = b.creditor_party
                 where c.user_id = p_owner and b.debtor_party = my_party() and b.outstanding_minor > 0) $$;

-- ------------------------------------------------------------------ extra RPCs
create function set_default_payment_method(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from payment_methods where id = p_id and owner_id = auth.uid()) then
    raise exception 'Not found' using errcode = '42501';
  end if;
  update payment_methods set is_default = false where owner_id = auth.uid() and is_default and id <> p_id;
  update payment_methods set is_default = true where id = p_id;
end $$;

create function revoke_group_invite(p_invite uuid) returns void language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select group_id into g from group_invites where id = p_invite;
  if g is null or not is_group_admin(g) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update group_invites set revoked_at = now() where id = p_invite and revoked_at is null;
end $$;


-- The payment methods a creditor has chosen to share with the caller, who must currently owe them money.
create function payment_methods_for_creditor(p_creditor_party uuid)
returns table (id uuid, provider text, method_type text, account_holder text, account_number text, nickname text, instructions text, is_default boolean)
language sql stable security definer set search_path = public as $$
  select m.id, m.provider, m.method_type, m.account_holder, m.account_number, m.nickname, m.instructions, m.is_default
  from payment_methods m join parties c on c.user_id = m.owner_id
  where c.id = p_creditor_party and m.shared_with_debtors
    and exists (select 1 from debt_balances b where b.debtor_party = my_party() and b.creditor_party = p_creditor_party and b.outstanding_minor > 0)
  order by m.is_default desc, m.created_at $$;

-- Guest contact details are only ever visible to the person who created the guest.
create view my_guests as
  select id, display_name, email, whatsapp, notes, claim_status, created_at
  from parties where kind = 'guest' and created_by = auth.uid() and merged_into is null;

-- ------------------------------------------------------------------ lock everything down
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated, public;
revoke all on all tables    in schema public from anon, authenticated, public;
revoke all on all sequences in schema public from anon, authenticated, public;
revoke all on all functions in schema public from anon, authenticated, public;

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ------------------------------------------------------------------ policies (read)
grant select on profiles, profile_contacts, profile_claims, known_parties, payment_methods, groups, group_members, group_invites,
               expenses, expense_items, item_allocations, expense_shares, contributions, debts, repayments, repayment_allocations,
               debt_adjustments, notifications, reminder_schedules, reminder_attempts, activity_events, app_settings
      to authenticated;
-- parties: contact columns (email/whatsapp/notes) are NOT selectable by clients; creators use my_guests.
grant select (id, kind, display_name, created_by, claim_status, merged_into, created_at) on parties to authenticated;
grant select on debt_balances, pair_balances, my_guests to authenticated;

create policy profiles_self        on profiles          for select to authenticated using (id = auth.uid());
create policy contacts_self        on profile_contacts  for select to authenticated using (profile_id = auth.uid());
create policy claims_self          on profile_claims    for select to authenticated using (claimant_id = auth.uid());
create policy known_self           on known_parties     for select to authenticated using (owner_id = auth.uid());
create policy parties_visible      on parties           for select to authenticated using (can_see_party(id));
create policy pm_owner_or_debtor   on payment_methods   for select to authenticated
  using (owner_id = auth.uid() or (shared_with_debtors and owes_money_to(owner_id)));
create policy groups_member        on groups            for select to authenticated using (owner_id = auth.uid() or is_group_member(id));
create policy members_visible      on group_members     for select to authenticated using (is_group_member(group_id) or controls_party(party_id));
create policy invites_admin        on group_invites     for select to authenticated using (is_group_admin(group_id));
create policy expenses_visible     on expenses          for select to authenticated using (can_see_expense(id));
create policy items_visible        on expense_items     for select to authenticated using (can_see_expense(expense_id));
create policy item_alloc_visible   on item_allocations  for select to authenticated
  using (can_see_expense((select i.expense_id from expense_items i where i.id = item_id)));
create policy shares_visible       on expense_shares    for select to authenticated using (can_see_expense(expense_id));
create policy contrib_visible      on contributions     for select to authenticated using (can_see_expense(expense_id));
create policy debts_visible        on debts             for select to authenticated using (can_see_expense(expense_id));
create policy repay_parties        on repayments        for select to authenticated using (controls_party(from_party) or controls_party(to_party));
create policy repay_alloc_visible  on repayment_allocations for select to authenticated using (can_see_repayment(repayment_id));
create policy adjust_visible       on debt_adjustments  for select to authenticated using (can_see_debt(debt_id));
create policy notif_self           on notifications     for select to authenticated using (user_id = auth.uid());
create policy rsched_visible       on reminder_schedules for select to authenticated using (can_see_debt(debt_id));
create policy rattempt_visible     on reminder_attempts for select to authenticated using (can_see_debt(debt_id));
create policy activity_audience    on activity_events   for select to authenticated using (auth.uid() = any (audience));
create policy settings_read        on app_settings      for select to authenticated using (true);

-- ------------------------------------------------------------------ the few direct writes
-- Own profile (cannot touch id / timestamps) and own payment methods.
grant update (display_name, avatar_url, email_discoverable, phone_discoverable, email_notifications, inapp_notifications)
      on profiles to authenticated;
create policy profiles_update_self on profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

grant insert (provider, method_type, account_holder, account_number, nickname, instructions, shared_with_debtors),
      update (provider, method_type, account_holder, account_number, nickname, instructions, shared_with_debtors),
      delete on payment_methods to authenticated;
create policy pm_insert on payment_methods for insert to authenticated with check (owner_id = auth.uid());
create policy pm_update on payment_methods for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy pm_delete on payment_methods for delete to authenticated using (owner_id = auth.uid());
alter table payment_methods alter column owner_id set default auth.uid();

grant update (name, description, avatar_url) on groups to authenticated;
create policy groups_update_admin on groups for update to authenticated using (is_group_admin(id)) with check (is_group_admin(id));

-- ------------------------------------------------------------------ RPC surface
grant execute on function
  my_party(), controls_party(uuid), is_group_member(uuid), is_group_admin(uuid), can_see_expense(uuid), can_see_party(uuid),
  can_see_debt(uuid), can_see_repayment(uuid), owes_money_to(uuid), norm_email(text), norm_phone(text), fmt_pkr(bigint)
  to authenticated;                                    -- needed by policies / views evaluated as the caller

grant execute on function
  create_guest(text, text, text, text), find_user(contact_kind, text), claim_guest_profile(uuid), merge_guest_profiles(uuid, uuid, text),
  create_group(text, text), create_group_invite(uuid, int, int), join_group(text), leave_group(uuid),
  remove_group_member(uuid, uuid, text), add_guest_to_group(uuid, uuid), transfer_group_ownership(uuid, uuid), revoke_group_invite(uuid),
  create_expense(jsonb), revise_expense(uuid, int, text, jsonb), set_share_reminders(uuid, uuid, boolean), void_expense(uuid, text),
  report_payment(text, uuid, uuid, bigint, text, text, text), confirm_payment(uuid, bigint), dispute_payment(uuid, text),
  reject_payment(uuid, text), record_cash(text, uuid, uuid, bigint), reverse_payment(uuid, text), adjust_debt(uuid, bigint, text),
  my_dashboard(), suggest_settlements(), whatsapp_reminder_target(uuid), mark_notification_read(uuid), mark_all_notifications_read(),
  register_device_token(text, text), set_default_payment_method(uuid), payment_methods_for_creditor(uuid)
  to authenticated;

-- Scheduler / email worker (Edge Functions with the service-role key, never the app):
grant usage on schema public to service_role;
grant execute on function claim_due_reminders(int, boolean), mark_reminder_attempt(uuid, text, text),
                          claim_email_notifications(int, boolean), mark_notification_email(uuid, text) to service_role;
