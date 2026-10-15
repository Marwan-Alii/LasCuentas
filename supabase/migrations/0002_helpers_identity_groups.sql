-- Helpers, identity, guest claiming, groups. Everything here runs as SECURITY DEFINER with a fixed
-- search_path; the acting user is ALWAYS auth.uid() and never a client-supplied id.

create table app_settings (key text primary key, value text not null);
insert into app_settings values ('reminder_grace_hours', '12'), ('reminder_default_max', '5');

-- ------------------------------------------------------------------ normalisation
create function norm_email(t text) returns text language sql immutable as $$ select nullif(lower(btrim(t)), '') $$;

-- digits only, Pakistani local format 03xx... -> 923xx...
create function norm_phone(t text) returns text language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(t, ''), '\D', '', 'g');
begin
  if d = '' then return null; end if;
  if d like '00%' then d := substr(d, 3); end if;
  if d like '0%' and length(d) = 11 then d := '92' || substr(d, 2); end if;
  return d;
end $$;

-- ------------------------------------------------------------------ access helpers
create function my_party() returns uuid language sql stable security definer set search_path = public as
$$ select id from parties where user_id = auth.uid() $$;

-- I act for my own party and for guests I created that are still unclaimed.
create function controls_party(p uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from parties x where x.id = p and
     (x.user_id = auth.uid() or (x.kind = 'guest' and x.created_by = auth.uid() and x.claim_status = 'unclaimed'))) $$;

create function is_group_member(g uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from group_members m where m.group_id = g and m.party_id = my_party() and m.status = 'active') $$;

create function is_group_admin(g uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from group_members m where m.group_id = g and m.party_id = my_party()
                   and m.status = 'active' and m.role in ('owner', 'admin')) $$;

create function can_see_expense(e uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from expenses x where x.id = e and (
       x.created_by = auth.uid()
    or exists (select 1 from expense_shares s where s.expense_id = e and controls_party(s.party_id))
    or exists (select 1 from contributions c where c.expense_id = e and controls_party(c.party_id))
    or (x.group_id is not null and is_group_member(x.group_id)))) $$;

-- Parties the caller may use in an expense: self, own guests, discovered users, or anyone sharing a group.
create function usable_party(p uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from parties x where x.id = p and x.merged_into is null) and (
       controls_party(p)
    or exists (select 1 from known_parties k where k.owner_id = auth.uid() and k.party_id = p)
    or exists (select 1 from group_members a join group_members b on a.group_id = b.group_id
               where a.party_id = my_party() and a.status = 'active' and b.party_id = p and b.status = 'active')) $$;

-- Profile ids that should see an audit event / receive a notification for these parties.
create function _audience(p_parties uuid[]) returns uuid[] language sql stable security definer set search_path = public as
$$ select coalesce(array_agg(distinct u), '{}') from (
     select user_id u from parties where id = any (p_parties) and user_id is not null
     union select created_by from parties where id = any (p_parties) and kind = 'guest'
     union select auth.uid()) q where u is not null $$;

create function _log(p_type text, p_subject_type text, p_subject uuid, p_expense uuid, p_group uuid,
                     p_before jsonb, p_after jsonb, p_reason text, p_audience uuid[])
returns void language sql security definer set search_path = public as
$$ insert into activity_events (actor_id, type, subject_type, subject_id, expense_id, group_id, before, after, reason, audience)
   values (auth.uid(), p_type, p_subject_type, p_subject, p_expense, p_group, p_before, p_after, p_reason,
           (select coalesce(array_agg(distinct x), '{}') from unnest(p_audience || array[auth.uid()]) x)) $$;

create function _notify(p_user uuid, p_kind text, p_title text, p_body text, p_data jsonb)
returns void language sql security definer set search_path = public as
$$ insert into notifications (user_id, kind, title, body, data)
   select p_user, p_kind, p_title, p_body, p_data
   from profiles where id = p_user and inapp_notifications and p_user is distinct from auth.uid() $$;

-- ------------------------------------------------------------------ signup / verified contacts
create function handle_auth_user() returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if tg_op = 'INSERT' then
    v_name := coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
                       split_part(coalesce(new.email, 'Member'), '@', 1));
    insert into profiles (id, display_name) values (new.id, left(v_name, 80));
    insert into parties (kind, user_id, display_name) values ('user', new.id, left(v_name, 80));
  end if;
  -- only verified identifiers become claimable / discoverable
  if new.email is not null and new.email_confirmed_at is not null then
    insert into profile_contacts (profile_id, kind, value) values (new.id, 'email', norm_email(new.email))
    on conflict (kind, value) do nothing;
  end if;
  if new.phone is not null and new.phone_confirmed_at is not null then
    insert into profile_contacts (profile_id, kind, value) values (new.id, 'whatsapp', norm_phone(new.phone))
    on conflict (kind, value) do nothing;
  end if;
  return new;
end $$;
create trigger on_auth_user_change after insert or update of email, phone, email_confirmed_at, phone_confirmed_at
  on auth.users for each row execute function handle_auth_user();

-- ------------------------------------------------------------------ people
create function create_guest(p_name text, p_email text default null, p_whatsapp text default null, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into parties (kind, display_name, email, whatsapp, notes, created_by, claim_status)
  values ('guest', btrim(p_name), norm_email(p_email), norm_phone(p_whatsapp), p_notes, auth.uid(), 'unclaimed')
  returning id into v;
  insert into known_parties (owner_id, party_id) values (auth.uid(), v);
  perform _log('GUEST_CREATED', 'party', v, null, null, null, jsonb_build_object('name', p_name), null, '{}');
  return v;
end $$;

-- Lookup by verified identifier. Returns nothing (never an error) when there is no match OR the
-- person is not discoverable, so existence of a private account cannot be probed.
create function find_user(p_kind contact_kind, p_value text)
returns table (party_id uuid, display_name text) language plpgsql security definer set search_path = public as $$
declare v_val text; v_party uuid; v_name text;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  v_val := case p_kind when 'email' then norm_email(p_value) else norm_phone(p_value) end;
  if v_val is null then return; end if;
  select pa.id, pr.display_name into v_party, v_name
  from profile_contacts c
  join profiles pr on pr.id = c.profile_id
  join parties pa on pa.user_id = pr.id
  where c.kind = p_kind and c.value = v_val
    and ((p_kind = 'email' and pr.email_discoverable) or (p_kind = 'whatsapp' and pr.phone_discoverable));
  if v_party is null then return; end if;
  insert into known_parties (owner_id, party_id) values (auth.uid(), v_party) on conflict do nothing;
  return query select v_party, v_name;
end $$;

-- ------------------------------------------------------------------ claiming / merging guests
-- Moves every financial reference from one party to another inside the caller's transaction.
create function _repoint_party(p_from uuid, p_to uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare n_shares int; n_contrib int; n_alloc int; n_debt int; n_rep int; n_mem int;
begin
  if exists (select 1 from expense_shares a join expense_shares b on a.expense_id = b.expense_id
             where a.party_id = p_from and b.party_id = p_to)
     or exists (select 1 from contributions a join contributions b on a.expense_id = b.expense_id
             where a.party_id = p_from and b.party_id = p_to)
     or exists (select 1 from debts where (debtor_party = p_from and creditor_party = p_to)
                                       or (debtor_party = p_to and creditor_party = p_from))
     or exists (select 1 from repayments where (from_party = p_from and to_party = p_to)
                                            or (from_party = p_to and to_party = p_from))
  then raise exception 'Both profiles appear in the same expense or settle with each other; they cannot be merged automatically'
       using errcode = '23505';
  end if;
  update item_allocations set party_id = p_to where party_id = p_from;   get diagnostics n_alloc = row_count;
  update expense_shares   set party_id = p_to where party_id = p_from;   get diagnostics n_shares = row_count;
  update contributions    set party_id = p_to where party_id = p_from;   get diagnostics n_contrib = row_count;
  update debts set debtor_party   = p_to where debtor_party = p_from;
  update debts set creditor_party = p_to where creditor_party = p_from;  get diagnostics n_debt = row_count;
  update repayments set from_party = p_to where from_party = p_from;
  update repayments set to_party   = p_to where to_party   = p_from;     get diagnostics n_rep = row_count;
  -- group membership is not financial: keep the target's row if both exist
  delete from group_members g where g.party_id = p_from
     and exists (select 1 from group_members t where t.group_id = g.group_id and t.party_id = p_to);
  update group_members set party_id = p_to where party_id = p_from;      get diagnostics n_mem = row_count;
  delete from known_parties where party_id = p_from;
  return jsonb_build_object('shares', n_shares, 'contributions', n_contrib, 'allocations', n_alloc,
                            'debts', n_debt, 'repayments', n_rep, 'memberships', n_mem);
end $$;

-- A guest profile can only be claimed by the account that has VERIFIED the guest's email/WhatsApp.
create function claim_guest_profile(p_guest uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare g parties; me uuid := my_party(); v_kind contact_kind; v_val text; v_moved jsonb;
begin
  if auth.uid() is null or me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into g from parties where id = p_guest and kind = 'guest' for update;     -- serialises concurrent claims
  if not found or g.claim_status <> 'unclaimed' or g.merged_into is not null then
    raise exception 'This guest profile cannot be claimed' using errcode = '22023';
  end if;
  select c.kind, c.value into v_kind, v_val from profile_contacts c
   where c.profile_id = auth.uid()
     and ((c.kind = 'email' and g.email is not null and c.value = g.email)
       or (c.kind = 'whatsapp' and g.whatsapp is not null and c.value = g.whatsapp))
   limit 1;
  if v_kind is null then
    raise exception 'Verify the email or WhatsApp number saved on this profile before claiming it' using errcode = '42501';
  end if;
  v_moved := _repoint_party(p_guest, me);
  update parties set claim_status = 'claimed', merged_into = me where id = p_guest;
  insert into profile_claims (guest_party_id, claimant_id, matched_kind, matched_value, moved)
  values (p_guest, auth.uid(), v_kind, v_val, v_moved);
  perform _log('GUEST_CLAIMED', 'party', p_guest, null, null, null,
               jsonb_build_object('claimed_by', auth.uid(), 'matched', v_kind, 'moved', v_moved), null,
               array[g.created_by]);
  return v_moved;
end $$;

-- Resolve duplicate guest profiles: the creator of BOTH may merge them.
create function merge_guest_profiles(p_from uuid, p_into uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a parties; b parties; v_moved jsonb;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into a from parties where id = p_from for update;
  select * into b from parties where id = p_into for update;
  if a.id is null or b.id is null or a.id = b.id or a.kind <> 'guest' or b.kind <> 'guest'
     or a.created_by <> auth.uid() or b.created_by <> auth.uid()
     or a.claim_status <> 'unclaimed' or b.claim_status <> 'unclaimed' then
    raise exception 'You can only merge two unclaimed guest profiles that you created' using errcode = '42501';
  end if;
  v_moved := _repoint_party(p_from, p_into);
  update parties set merged_into = p_into, claim_status = 'claimed' where id = p_from;
  perform _log('GUEST_MERGED', 'party', p_from, null, null, to_jsonb(a) - 'notes', jsonb_build_object('into', p_into, 'moved', v_moved), p_reason, '{}');
  return v_moved;
end $$;

-- ------------------------------------------------------------------ groups
create function create_group(p_name text, p_description text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into groups (name, description, owner_id) values (btrim(p_name), p_description, auth.uid()) returning id into g;
  insert into group_members (group_id, party_id, role, added_by) values (g, my_party(), 'owner', auth.uid());
  perform _log('GROUP_CREATED', 'group', g, null, g, null, jsonb_build_object('name', p_name), null, '{}');
  return g;
end $$;

-- Returns the plain code ONCE; only its SHA-256 is stored.
create function create_group_invite(p_group uuid, p_valid_hours int default 72, p_max_uses int default 10) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
begin
  if not is_group_admin(p_group) then raise exception 'Only group admins can invite' using errcode = '42501'; end if;
  insert into group_invites (group_id, code_hash, created_by, expires_at, max_uses)
  values (p_group, sha256(convert_to(v_code, 'utf8')), auth.uid(), now() + make_interval(hours => least(p_valid_hours, 720)), p_max_uses);
  return v_code;
end $$;

create function join_group(p_code text) returns uuid language plpgsql security definer set search_path = public as $$
declare i group_invites; me uuid := my_party();
begin
  if auth.uid() is null or me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into i from group_invites where code_hash = sha256(convert_to(upper(btrim(p_code)), 'utf8')) for update;
  if not found or i.revoked_at is not null or i.expires_at < now() or i.uses >= i.max_uses then
    raise exception 'Invalid or expired invite' using errcode = '22023';
  end if;
  if exists (select 1 from group_members where group_id = i.group_id and party_id = me and status = 'removed') then
    raise exception 'Invalid or expired invite' using errcode = '22023';   -- removed members cannot rejoin by code
  end if;
  insert into group_members (group_id, party_id, role, added_by) values (i.group_id, me, 'member', i.created_by)
  on conflict (group_id, party_id) do update set status = 'active', left_at = null
     where group_members.status = 'left';
  update group_invites set uses = uses + 1 where id = i.id;
  perform _log('MEMBER_JOINED', 'group', i.group_id, null, i.group_id, null, jsonb_build_object('party', me), null,
               (select array_agg(user_id) from parties p join group_members m on m.party_id = p.id
                where m.group_id = i.group_id and m.status = 'active' and p.user_id is not null));
  return i.group_id;
end $$;

create function leave_group(p_group uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from group_members where group_id = p_group and party_id = my_party() and role = 'owner' and status = 'active') then
    raise exception 'Transfer ownership before leaving' using errcode = '22023';
  end if;
  update group_members set status = 'left', left_at = now() where group_id = p_group and party_id = my_party() and status = 'active';
  if not found then raise exception 'Not a member' using errcode = '22023'; end if;
  perform _log('MEMBER_LEFT', 'group', p_group, null, p_group, null, jsonb_build_object('party', my_party()), null, '{}');
end $$;

-- Removing a member never touches their expenses, debts or audit history.
create function remove_group_member(p_group uuid, p_party uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t group_members;
begin
  if not is_group_admin(p_group) then raise exception 'Only group admins can remove members' using errcode = '42501'; end if;
  select * into t from group_members where group_id = p_group and party_id = p_party and status = 'active';
  if not found then raise exception 'Not an active member' using errcode = '22023'; end if;
  if t.role = 'owner' then raise exception 'The owner cannot be removed' using errcode = '42501'; end if;
  update group_members set status = 'removed', left_at = now() where group_id = p_group and party_id = p_party;
  perform _log('MEMBER_REMOVED', 'group', p_group, null, p_group, null, jsonb_build_object('party', p_party), p_reason, _audience(array[p_party]));
end $$;

-- Guests are added to a group by the person who created them (and who is an admin).
create function add_guest_to_group(p_group uuid, p_guest uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_group_admin(p_group) then raise exception 'Only group admins can add members' using errcode = '42501'; end if;
  if not exists (select 1 from parties where id = p_guest and kind = 'guest' and created_by = auth.uid() and merged_into is null) then
    raise exception 'You can only add guests you created' using errcode = '42501';
  end if;
  insert into group_members (group_id, party_id, added_by) values (p_group, p_guest, auth.uid())
  on conflict (group_id, party_id) do update set status = 'active', left_at = null;
  perform _log('MEMBER_ADDED', 'group', p_group, null, p_group, null, jsonb_build_object('party', p_guest), null, '{}');
end $$;

create function transfer_group_ownership(p_group uuid, p_new_owner_party uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if not exists (select 1 from groups where id = p_group and owner_id = auth.uid()) then
    raise exception 'Only the owner can transfer ownership' using errcode = '42501';
  end if;
  select user_id into v_user from parties where id = p_new_owner_party and user_id is not null;
  if v_user is null or not exists (select 1 from group_members where group_id = p_group and party_id = p_new_owner_party and status = 'active') then
    raise exception 'New owner must be an active registered member' using errcode = '22023';
  end if;
  update group_members set role = 'admin' where group_id = p_group and party_id = my_party();
  update group_members set role = 'owner' where group_id = p_group and party_id = p_new_owner_party;
  update groups set owner_id = v_user where id = p_group;
  perform _log('OWNERSHIP_TRANSFERRED', 'group', p_group, null, p_group, null, jsonb_build_object('to', v_user), null, array[v_user]);
end $$;
