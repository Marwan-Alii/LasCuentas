-- Balances (derived), repayments with recipient confirmation, adjustments, notifications, reminders.

-- ------------------------------------------------------------------ derived balances (no stored totals)
create view debt_balances with (security_invoker = true) as
select d.id as debt_id, d.expense_id, d.debtor_party, d.creditor_party, d.seq, e.title as expense_title,
       d.amount_minor as original_minor, x.adj as adjustment_minor, x.paid as confirmed_paid_minor,
       case when e.status = 'active' then d.amount_minor + x.adj - x.paid else 0 end as outstanding_minor,
       e.status as expense_status
from debts d
join expenses e on e.id = d.expense_id
cross join lateral (select coalesce((select sum(delta_minor) from debt_adjustments a where a.debt_id = d.id), 0)::bigint as adj,
                           coalesce((select sum(amount_minor) from repayment_allocations r where r.debt_id = d.id), 0)::bigint as paid) x;

create view pair_balances with (security_invoker = true) as
select b.debtor_party, b.creditor_party,
       sum(b.original_minor + b.adjustment_minor)::bigint as original_minor,
       sum(b.confirmed_paid_minor)::bigint        as confirmed_received_minor,
       sum(b.outstanding_minor)::bigint             as outstanding_minor,
       coalesce((select sum(r.reported_minor) from repayments r
                 where r.from_party = b.debtor_party and r.to_party = b.creditor_party and r.status in ('reported', 'disputed')), 0)::bigint as awaiting_confirmation_minor,
       exists (select 1 from repayments r where r.from_party = b.debtor_party and r.to_party = b.creditor_party and r.status = 'disputed') as has_dispute
from debt_balances b
where b.expense_status = 'active'
group by b.debtor_party, b.creditor_party;

create function _pair_outstanding(p_from uuid, p_to uuid) returns bigint language sql stable security definer set search_path = public as
$$ select coalesce(sum(outstanding_minor), 0) from debt_balances where debtor_party = p_from and creditor_party = p_to $$;

-- The person who should be told about something concerning this party.
create function _party_user(p uuid) returns uuid language sql stable security definer set search_path = public as
$$ select coalesce(user_id, created_by) from parties where id = p $$;

create function _pair_lock(p_from uuid, p_to uuid) returns void language sql security definer set search_path = public as
$$ select pg_advisory_xact_lock(hashtextextended(p_from::text || p_to::text, 0)) $$;

create function _pair_audience(p_from uuid, p_to uuid) returns uuid[] language sql stable security definer set search_path = public as
$$ select _audience(array[p_from, p_to]) $$;

-- Re-arm or stop reminders after a balance change.
create function _refresh_pair_reminders(p_from uuid, p_to uuid) returns void language sql security definer set search_path = public as $$
  update reminder_schedules rs set
     next_due_at = case when b.outstanding_minor <= 0 then 'infinity'::timestamptz
                        when rs.next_due_at = 'infinity' then now() + make_interval(hours => rs.interval_hours)
                        else rs.next_due_at end,
     paused_until = case when b.outstanding_minor <= 0
                           or not exists (select 1 from repayments r where r.from_party = p_from and r.to_party = p_to
                                          and r.status in ('reported', 'disputed'))
                         then null else rs.paused_until end
  from debt_balances b where b.debt_id = rs.debt_id and b.debtor_party = p_from and b.creditor_party = p_to $$;

-- ------------------------------------------------------------------ repayment workflow
create function report_payment(p_key text, p_from uuid, p_to uuid, p_amount bigint,
                               p_reference text default null, p_note text default null, p_screenshot text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; r repayments; v_out bigint; v_name text; v_grace int;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not controls_party(p_from) then raise exception 'You can only report your own payments' using errcode = '42501'; end if;
  select * into r from repayments where created_by = auth.uid() and idempotency_key = p_key;
  if found then       -- retry of the same request: return the original, never a duplicate
    if r.from_party <> p_from or r.to_party <> p_to or r.reported_minor <> p_amount then
      raise exception 'Idempotency key was already used for a different payment' using errcode = '22023';
    end if;
    return r.id;
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be greater than zero' using errcode = '22023'; end if;
  perform _pair_lock(p_from, p_to);
  v_out := _pair_outstanding(p_from, p_to);
  if v_out <= 0 then raise exception 'Nothing is owed to this person' using errcode = '22023'; end if;
  if p_amount > v_out then raise exception 'Amount (%) is more than the outstanding %', fmt_pkr(p_amount), fmt_pkr(v_out) using errcode = '22023'; end if;
  insert into repayments (idempotency_key, created_by, from_party, to_party, reported_minor, reference, note, screenshot_path)
  values (p_key, auth.uid(), p_from, p_to, p_amount, p_reference, p_note, p_screenshot) returning id into v_id;
  select value::int into v_grace from app_settings where key = 'reminder_grace_hours';
  update reminder_schedules set paused_until = now() + make_interval(hours => v_grace)
   where debt_id in (select debt_id from debt_balances where debtor_party = p_from and creditor_party = p_to);
  select display_name into v_name from parties where id = p_from;
  perform _notify(_party_user(p_to), 'payment_reported', 'Payment reported',
                  v_name || ' says they paid ' || fmt_pkr(p_amount) || '. Confirm once you have received it.',
                  jsonb_build_object('repayment_id', v_id));
  perform _log('PAYMENT_REPORTED', 'repayment', v_id, null, null, null,
               jsonb_build_object('amount_minor', p_amount, 'from', p_from, 'to', p_to), null, _pair_audience(p_from, p_to));
  return v_id;
end $$;

-- FIFO application of confirmed money to the pair's debts (oldest expense first).
create function _apply_confirmed(p_rep uuid, p_amount bigint, p_from uuid, p_to uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d record; v_left bigint := p_amount; x bigint;
begin
  for d in select debt_id, outstanding_minor from debt_balances
           where debtor_party = p_from and creditor_party = p_to and outstanding_minor > 0 order by seq, debt_id loop
    exit when v_left = 0;
    x := least(d.outstanding_minor, v_left);
    insert into repayment_allocations (repayment_id, debt_id, amount_minor) values (p_rep, d.debt_id, x);
    v_left := v_left - x;
  end loop;
  if v_left > 0 then raise exception 'Amount exceeds what is outstanding' using errcode = '22023'; end if;
  perform _refresh_pair_reminders(p_from, p_to);
end $$;

create function confirm_payment(p_repayment uuid, p_amount bigint) returns void language plpgsql security definer set search_path = public as $$
declare r repayments; v_name text;
begin
  select * into r from repayments where id = p_repayment for update;
  if not found or not controls_party(r.to_party) then raise exception 'Only the recipient can confirm receipt' using errcode = '42501'; end if;
  if r.status = 'confirmed' then
    if r.confirmed_minor = p_amount then return; end if;           -- idempotent retry
    raise exception 'Already confirmed with a different amount' using errcode = '22023';
  end if;
  if r.status not in ('reported', 'disputed') then raise exception 'This payment can no longer be confirmed' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > r.reported_minor then
    raise exception 'Confirmed amount must be between 1 paisa and the reported amount' using errcode = '22023';
  end if;
  perform _pair_lock(r.from_party, r.to_party);
  if p_amount > _pair_outstanding(r.from_party, r.to_party) then
    raise exception 'Confirmed amount exceeds what is outstanding' using errcode = '22023';
  end if;
  update repayments set status = 'confirmed', confirmed_minor = p_amount, confirmed_at = now() where id = p_repayment;
  perform _apply_confirmed(p_repayment, p_amount, r.from_party, r.to_party);
  select display_name into v_name from parties where id = r.to_party;
  perform _notify(_party_user(r.from_party), 'payment_confirmed', 'Payment confirmed',
                  v_name || ' confirmed ' || fmt_pkr(p_amount) || '. Remaining: ' || fmt_pkr(_pair_outstanding(r.from_party, r.to_party)) || '.',
                  jsonb_build_object('repayment_id', p_repayment));
  perform _log('PAYMENT_CONFIRMED', 'repayment', p_repayment, null, null,
               jsonb_build_object('reported_minor', r.reported_minor), jsonb_build_object('confirmed_minor', p_amount), null,
               _pair_audience(r.from_party, r.to_party));
end $$;

create function _resolve_report(p_repayment uuid, p_new repayment_status, p_reason text, p_kind text, p_title text)
returns void language plpgsql security definer set search_path = public as $$
declare r repayments;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required' using errcode = '22023'; end if;
  select * into r from repayments where id = p_repayment for update;
  if not found or not controls_party(r.to_party) then raise exception 'Only the recipient can do this' using errcode = '42501'; end if;
  if not (r.status = 'reported' or (r.status = 'disputed' and p_new = 'rejected')) then
    raise exception 'This payment cannot be % now', lower(p_new::text) using errcode = '22023';
  end if;
  update repayments set status = p_new, reason = p_reason where id = p_repayment;
  perform _refresh_pair_reminders(r.from_party, r.to_party);   -- a response ends the pause
  perform _notify(_party_user(r.from_party), p_kind, p_title, p_reason, jsonb_build_object('repayment_id', p_repayment));
  perform _log(upper(p_kind), 'repayment', p_repayment, null, null, jsonb_build_object('status', r.status), jsonb_build_object('status', p_new), p_reason,
               _pair_audience(r.from_party, r.to_party));
end $$;
create function dispute_payment(p_repayment uuid, p_reason text) returns void language sql security definer set search_path = public as
$$ select _resolve_report(p_repayment, 'disputed', p_reason, 'payment_disputed', 'Payment disputed') $$;
create function reject_payment(p_repayment uuid, p_reason text) returns void language sql security definer set search_path = public as
$$ select _resolve_report(p_repayment, 'rejected', p_reason, 'payment_rejected', 'Payment not received') $$;

-- Recipient records cash handed over directly: confirmed immediately.
create function record_cash(p_key text, p_from uuid, p_to uuid, p_amount bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; r repayments;
begin
  if not controls_party(p_to) then raise exception 'Only the recipient can record cash received' using errcode = '42501'; end if;
  select * into r from repayments where created_by = auth.uid() and idempotency_key = p_key;
  if found then return r.id; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be greater than zero' using errcode = '22023'; end if;
  perform _pair_lock(p_from, p_to);
  if p_amount > _pair_outstanding(p_from, p_to) then raise exception 'Amount is more than the outstanding balance' using errcode = '22023'; end if;
  insert into repayments (idempotency_key, created_by, from_party, to_party, reported_minor, confirmed_minor, status, cash_recorded, confirmed_at)
  values (p_key, auth.uid(), p_from, p_to, p_amount, p_amount, 'confirmed', true, now()) returning id into v_id;
  perform _apply_confirmed(v_id, p_amount, p_from, p_to);
  perform _notify(_party_user(p_from), 'payment_confirmed', 'Cash payment recorded', fmt_pkr(p_amount) || ' received in cash.', jsonb_build_object('repayment_id', v_id));
  perform _log('CASH_RECORDED', 'repayment', v_id, null, null, null, jsonb_build_object('amount_minor', p_amount), null, _pair_audience(p_from, p_to));
  return v_id;
end $$;

-- Corrects a confirmed payment with compensating rows. Nothing is deleted or edited.
create function reverse_payment(p_repayment uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare r repayments;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required' using errcode = '22023'; end if;
  select * into r from repayments where id = p_repayment for update;
  if not found or not controls_party(r.to_party) then raise exception 'Only the recipient can reverse a payment' using errcode = '42501'; end if;
  if r.status <> 'confirmed' then raise exception 'Only a confirmed payment can be reversed' using errcode = '22023'; end if;
  perform _pair_lock(r.from_party, r.to_party);
  insert into repayment_allocations (repayment_id, debt_id, amount_minor, reverses)
  select a.repayment_id, a.debt_id, -a.amount_minor, a.id from repayment_allocations a
   where a.repayment_id = p_repayment and a.amount_minor > 0
     and not exists (select 1 from repayment_allocations x where x.reverses = a.id);
  update repayments set status = 'reversed', reason = p_reason where id = p_repayment;
  perform _refresh_pair_reminders(r.from_party, r.to_party);
  perform _notify(_party_user(r.from_party), 'payment_reversed', 'Payment reversed', p_reason, jsonb_build_object('repayment_id', p_repayment));
  perform _log('PAYMENT_REVERSED', 'repayment', p_repayment, null, null, jsonb_build_object('confirmed_minor', r.confirmed_minor),
               jsonb_build_object('status', 'reversed'), p_reason, _pair_audience(r.from_party, r.to_party));
end $$;

-- Creditor forgives part of a debt. Append-only; never exceeds what is outstanding.
create function adjust_debt(p_debt uuid, p_reduce_by bigint, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare d debts;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required' using errcode = '22023'; end if;
  select * into d from debts where id = p_debt;
  if not found or not controls_party(d.creditor_party) then raise exception 'Only the person owed can adjust a debt' using errcode = '42501'; end if;
  perform _pair_lock(d.debtor_party, d.creditor_party);
  if p_reduce_by is null or p_reduce_by <= 0 or p_reduce_by > (select outstanding_minor from debt_balances where debt_id = p_debt) then
    raise exception 'Reduction must be positive and not more than the outstanding amount' using errcode = '22023';
  end if;
  insert into debt_adjustments (debt_id, delta_minor, reason, actor_id) values (p_debt, -p_reduce_by, p_reason, auth.uid());
  perform _refresh_pair_reminders(d.debtor_party, d.creditor_party);
  perform _notify(_party_user(d.debtor_party), 'debt_adjusted', 'Amount reduced', fmt_pkr(p_reduce_by) || ' was taken off what you owe. ' || p_reason,
                  jsonb_build_object('debt_id', p_debt, 'expense_id', d.expense_id));
  perform _log('DEBT_ADJUSTED', 'debt', p_debt, d.expense_id, null, null, jsonb_build_object('delta_minor', -p_reduce_by), p_reason,
               _pair_audience(d.debtor_party, d.creditor_party));
end $$;

-- ------------------------------------------------------------------ reads for the app
create function my_dashboard() returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'owed_to_me_minor', coalesce((select sum(outstanding_minor) from debt_balances where controls_party(creditor_party)), 0),
    'i_owe_minor',      coalesce((select sum(outstanding_minor) from debt_balances where debtor_party = my_party()), 0),
    'awaiting_my_confirmation', (select count(*) from repayments where status in ('reported', 'disputed') and controls_party(to_party)),
    'my_reports_awaiting',      (select count(*) from repayments where status in ('reported', 'disputed') and created_by = auth.uid()),
    'unread_notifications',     (select count(*) from notifications where user_id = auth.uid() and read_at is null)) $$;

-- Pairwise netting across expenses, for pairs involving the caller. Recommendations only: recording
-- one is a normal report_payment, applied oldest-debt-first, and the breakdown below shows how.
create function suggest_settlements() returns table (from_party uuid, to_party uuid, amount_minor bigint,
                                                     gross_owed_minor bigint, gross_owed_back_minor bigint, allocation jsonb)
language plpgsql stable security invoker set search_path = public as $$
declare r record;
begin
  for r in
    select a, b, ab, ba from (
      select least(debtor_party, creditor_party) a, greatest(debtor_party, creditor_party) b,
             (sum(outstanding_minor) filter (where debtor_party < creditor_party))::bigint ab,
             (sum(outstanding_minor) filter (where debtor_party > creditor_party))::bigint ba
      from debt_balances where outstanding_minor > 0 and (debtor_party = my_party() or creditor_party = my_party())
      group by 1, 2) q
  loop
    r.ab := coalesce(r.ab, 0);  r.ba := coalesce(r.ba, 0);
    continue when r.ab = r.ba;
    from_party := case when r.ab > r.ba then r.a else r.b end;
    to_party   := case when r.ab > r.ba then r.b else r.a end;
    gross_owed_minor := greatest(r.ab, r.ba);  gross_owed_back_minor := least(r.ab, r.ba);
    amount_minor := gross_owed_minor - gross_owed_back_minor;
    select coalesce(jsonb_agg(jsonb_build_object('debt_id', debt_id, 'amount_minor', take) order by seq), '[]') into allocation
      from (select debt_id, seq, least(outstanding_minor, greatest(0, amount_minor - coalesce(sum(outstanding_minor) over (order by seq, debt_id rows between unbounded preceding and 1 preceding), 0)::bigint)) take
            from debt_balances where debtor_party = from_party and creditor_party = to_party and outstanding_minor > 0) z
      where take > 0;
    return next;
  end loop;
end $$;

-- Manual WhatsApp reminder target: only the person owed, and only a number they are entitled to see.
create function whatsapp_reminder_target(p_debt uuid) returns table (phone text, message text)
language sql stable security definer set search_path = public as $$
  select coalesce(pa.whatsapp, (select c.value from profile_contacts c where c.profile_id = pa.user_id and c.kind = 'whatsapp'
                                  and pr.phone_discoverable)),
         'Hi ' || split_part(pa.display_name, ' ', 1) || ', your remaining share for ' || b.expense_title || ' is ' ||
         fmt_pkr(b.outstanding_minor) || '. Please send it when convenient. Thanks!'
  from debt_balances b
  join parties pa on pa.id = b.debtor_party
  left join profiles pr on pr.id = pa.user_id
  where b.debt_id = p_debt and b.outstanding_minor > 0 and controls_party(b.creditor_party) $$;

-- ------------------------------------------------------------------ notifications
alter table notifications add column email_status text not null default 'pending'
  check (email_status in ('pending', 'sending', 'sent', 'failed', 'skipped'));
alter table notifications add column emailed_at timestamptz;

create function mark_notification_read(p_id uuid) returns void language sql security definer set search_path = public as
$$ update notifications set read_at = coalesce(read_at, now()) where id = p_id and user_id = auth.uid() $$;
create function mark_all_notifications_read() returns int language sql security definer set search_path = public as
$$ with u as (update notifications set read_at = now() where user_id = auth.uid() and read_at is null returning 1) select count(*)::int from u $$;

create function register_device_token(p_token text, p_platform text default 'android') returns void
language sql security definer set search_path = public as $$
  insert into device_tokens (user_id, token, platform) values (auth.uid(), p_token, p_platform)
  on conflict (token) do update set user_id = auth.uid() $$;

-- ------------------------------------------------------------------ reminders (service_role only)
-- Atomically claims every reminder that is due, rechecking eligibility, and advances its schedule.
-- UNIQUE(debt_id, sequence, channel) plus FOR UPDATE SKIP LOCKED make a repeated or overlapping run harmless.
create function claim_due_reminders(p_limit int default 100, p_email_enabled boolean default true)
returns table (attempt_id uuid, channel text, debt_id uuid, expense_id uuid, sequence int, amount_minor bigint,
               recipient text, debtor_name text, creditor_name text, expense_title text)
language plpgsql security definer set search_path = public as $$
declare r record; v_out bigint; v_seq int; v_email text; v_user uuid; v_attempt uuid; v_inapp boolean; v_email_ok boolean;
begin
  for r in
    select rs.debt_id as did, rs.sent_count, rs.interval_hours, d.expense_id as eid, d.debtor_party, d.creditor_party,
           e.title, dp.display_name as dname, cp.display_name as cname, dp.user_id, dp.email as guest_email
    from reminder_schedules rs
    join debts d on d.id = rs.debt_id
    join expenses e on e.id = d.expense_id and e.status = 'active'
    join expense_shares es on es.expense_id = d.expense_id and es.party_id = d.debtor_party and es.remind
    join parties dp on dp.id = d.debtor_party
    join parties cp on cp.id = d.creditor_party
    where rs.next_due_at <= now() and (rs.paused_until is null or rs.paused_until <= now()) and rs.sent_count < rs.max_count
    order by rs.next_due_at for update of rs skip locked limit p_limit
  loop
    select b.outstanding_minor into v_out from debt_balances b where b.debt_id = r.did;
    if v_out is null or v_out <= 0 then
      update reminder_schedules set next_due_at = 'infinity' where reminder_schedules.debt_id = r.did;
      continue;
    end if;
    v_seq := r.sent_count + 1;
    v_inapp := false; v_email := null; v_email_ok := false;
    if r.user_id is not null then
      select p.inapp_notifications, case when p.email_notifications then
               (select c.value from profile_contacts c where c.profile_id = p.id and c.kind = 'email' limit 1) end
        into v_inapp, v_email from profiles p where p.id = r.user_id;
    else
      v_email := r.guest_email;       -- guests have no app; email only
    end if;
    update reminder_schedules set sent_count = v_seq, next_due_at = now() + make_interval(hours => r.interval_hours)
     where reminder_schedules.debt_id = r.did;

    if v_inapp then
      insert into reminder_attempts (debt_id, sequence, channel, status, amount_minor, recipient)
      values (r.did, v_seq, 'inapp', 'sent', v_out, r.user_id::text) on conflict do nothing returning id into v_attempt;
      if v_attempt is not null then
        insert into notifications (user_id, kind, title, body, data, email_status)
        values (r.user_id, 'reminder', 'Reminder: ' || r.title,
                'You still owe ' || fmt_pkr(v_out) || ' to ' || r.cname || ' for ' || r.title || '.',
                jsonb_build_object('expense_id', r.eid, 'debt_id', r.did), 'skipped');
      end if;
    end if;

    v_attempt := null;
    insert into reminder_attempts (debt_id, sequence, channel, status, amount_minor, recipient, error)
    values (r.did, v_seq, 'email',
            case when v_email is null then 'skipped' when not p_email_enabled then 'skipped' else 'claimed' end,
            v_out, v_email,
            case when v_email is null then 'no email address or email notifications off'
                 when not p_email_enabled then 'email provider not configured' end)
    on conflict do nothing returning id into v_attempt;
    if v_attempt is not null and v_email is not null and p_email_enabled then
      attempt_id := v_attempt; channel := 'email'; debt_id := r.did; expense_id := r.eid; sequence := v_seq;
      amount_minor := v_out; recipient := v_email; debtor_name := r.dname; creditor_name := r.cname; expense_title := r.title;
      return next;
    end if;
  end loop;
end $$;

create function mark_reminder_attempt(p_attempt uuid, p_status text, p_error text default null) returns void
language sql security definer set search_path = public as $$
  update reminder_attempts set status = p_status, error = p_error where id = p_attempt and status = 'claimed' and p_status in ('sent', 'failed') $$;

-- Emails for non-reminder notifications (payment reported/confirmed/disputed, new debt ...).
create function claim_email_notifications(p_limit int default 50, p_email_enabled boolean default true)
returns table (notification_id uuid, recipient text, title text, body text, kind text, data jsonb)
language plpgsql security definer set search_path = public as $$
begin
  if not p_email_enabled then
    update notifications set email_status = 'skipped' where email_status = 'pending';     -- honest: never marked 'sent'
    return;
  end if;
  return query
  with c as (
    select n.id from notifications n where n.email_status = 'pending' order by n.created_at for update skip locked limit p_limit),
  u as (update notifications n set email_status = 'sending'
        from c where n.id = c.id returning n.*)
  select u.id,
         (select ct.value from profile_contacts ct join profiles p on p.id = ct.profile_id
           where ct.profile_id = u.user_id and ct.kind = 'email' and p.email_notifications limit 1),
         u.title, u.body, u.kind, u.data
  from u;
end $$;

create function mark_notification_email(p_id uuid, p_status text) returns void language sql security definer set search_path = public as $$
  update notifications set email_status = p_status, emailed_at = case when p_status = 'sent' then now() end
   where id = p_id and email_status = 'sending' and p_status in ('sent', 'failed', 'skipped') $$;
