-- Expense writes. Clients send item allocations (computed by the shared Kotlin engine); the server
-- re-validates every invariant and derives the debts itself. Clients cannot insert into these tables.

create function fmt_pkr(p bigint) returns text language sql immutable as $$
  select (case when p < 0 then '-' else '' end) || 'Rs. ' ||
         trim(to_char(abs(p) / 100, 'FM999,999,999,999')) ||
         case when abs(p) % 100 = 0 then '' else '.' || lpad((abs(p) % 100)::text, 2, '0') end $$;

create function _check_party(p uuid, p_group uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not usable_party(p) then raise exception 'You cannot include this person in an expense' using errcode = '42501'; end if;
  if p_group is not null and not exists
     (select 1 from group_members where group_id = p_group and party_id = p and status = 'active') then
    raise exception 'Everyone in a group expense must be an active member of that group' using errcode = '42501';
  end if;
end $$;

-- Greedy largest-first matching of debtors to creditors (port of DebtDeriver in the Kotlin core).
create function _derive_debts(p_expense uuid) returns int language plpgsql security definer set search_path = public as $$
declare
  e expenses; dids uuid[]; damt bigint[]; cids uuid[]; camt bigint[];
  di int := 1; ci int := 1; x bigint; n int := 0; v_debt uuid;
begin
  select * into e from expenses where id = p_expense;
  if e.unpaid_minor <> 0 then return 0; end if;       -- incomplete expense: no guessed debts
  select array_agg(party order by -net, party), array_agg(-net order by -net, party) into dids, damt
    from (select coalesce(s.party_id, c.party_id) party, coalesce(c.amount_minor, 0) - coalesce(s.share_minor, 0) net
          from expense_shares s full join contributions c on c.expense_id = s.expense_id and c.party_id = s.party_id
          where coalesce(s.expense_id, c.expense_id) = p_expense) q where net < 0;
  select array_agg(party order by -net, party), array_agg(net order by -net, party) into cids, camt
    from (select coalesce(s.party_id, c.party_id) party, coalesce(c.amount_minor, 0) - coalesce(s.share_minor, 0) net
          from expense_shares s full join contributions c on c.expense_id = s.expense_id and c.party_id = s.party_id
          where coalesce(s.expense_id, c.expense_id) = p_expense) q where net > 0;
  while dids is not null and cids is not null and di <= array_length(dids, 1) and ci <= array_length(cids, 1) loop
    x := least(damt[di], camt[ci]);
    insert into debts (expense_id, debtor_party, creditor_party, amount_minor)
    values (p_expense, dids[di], cids[ci], x) returning id into v_debt;
    insert into reminder_schedules (debt_id, interval_hours, max_count, next_due_at)
    values (v_debt, e.reminder_interval_h, e.reminder_max, e.created_at + make_interval(hours => e.reminder_interval_h));
    damt[di] := damt[di] - x; camt[ci] := camt[ci] - x; n := n + 1;
    if damt[di] = 0 then di := di + 1; end if;
    if camt[ci] = 0 then ci := ci + 1; end if;
  end loop;
  return n;
end $$;

create function _write_expense_body(p_expense uuid, p jsonb, p_group uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  it jsonb; al jsonb; ct jsonb; v_item uuid; v_qty int; v_unit bigint; v_line bigint; v_sum bigint; v_units int;
  v_total bigint := 0; v_contrib bigint := 0; v_party uuid; v_amt bigint; v_method text; v_pos int := 0;
begin
  if jsonb_typeof(p -> 'items') is distinct from 'array' or jsonb_array_length(p -> 'items') not between 1 and 200 then
    raise exception 'An expense needs between 1 and 200 items' using errcode = '22023';
  end if;
  for it in select * from jsonb_array_elements(p -> 'items') loop
    v_qty := (it ->> 'quantity')::int;  v_unit := (it ->> 'unit_minor')::bigint;
    v_method := coalesce(it ->> 'method', 'equal');
    if v_qty is null or v_qty < 1 then raise exception 'Quantity must be at least 1' using errcode = '22023'; end if;
    if v_unit is null or v_unit < 0 then raise exception 'Price cannot be negative' using errcode = '22023'; end if;
    v_line := v_qty::bigint * v_unit;
    insert into expense_items (expense_id, kind, name, quantity, unit_minor, line_minor, method, category, notes, position)
    values (p_expense, coalesce(it ->> 'kind', 'item'), btrim(it ->> 'name'), v_qty, v_unit, v_line, v_method,
            it ->> 'category', it ->> 'notes', v_pos)
    returning id into v_item;
    v_sum := 0; v_units := 0;
    for al in select * from jsonb_array_elements(coalesce(it -> 'allocations', '[]')) loop
      v_party := (al ->> 'party_id')::uuid;  v_amt := (al ->> 'amount_minor')::bigint;
      if v_amt is null or v_amt < 0 then raise exception 'Allocation cannot be negative' using errcode = '22023'; end if;
      perform _check_party(v_party, p_group);
      insert into item_allocations (item_id, party_id, amount_minor, units)
      values (v_item, v_party, v_amt, nullif(al ->> 'units', '')::int);
      v_sum := v_sum + v_amt;  v_units := v_units + coalesce((al ->> 'units')::int, 0);
    end loop;
    if v_sum <> v_line then
      raise exception 'Allocations for "%" (%) must equal its total (%)', it ->> 'name', fmt_pkr(v_sum), fmt_pkr(v_line) using errcode = '22023';
    end if;
    if v_method = 'quantity' and v_units <> v_qty then
      raise exception 'Units assigned for "%" must equal its quantity', it ->> 'name' using errcode = '22023';
    end if;
    v_total := v_total + v_line;  v_pos := v_pos + 1;
  end loop;
  if v_total <= 0 then raise exception 'Expense total must be greater than zero' using errcode = '22023'; end if;
  if p ? 'total_minor' and (p ->> 'total_minor')::bigint <> v_total then
    raise exception 'Recorded total (%) does not match the items (%)', fmt_pkr((p ->> 'total_minor')::bigint), fmt_pkr(v_total) using errcode = '22023';
  end if;

  insert into expense_shares (expense_id, party_id, share_minor, remind)
  select p_expense, ia.party_id, sum(ia.amount_minor),
         coalesce((p -> 'remind' ->> ia.party_id::text)::boolean, true)
  from item_allocations ia join expense_items ei on ei.id = ia.item_id
  where ei.expense_id = p_expense group by ia.party_id;

  for ct in select * from jsonb_array_elements(coalesce(p -> 'contributions', '[]')) loop
    v_party := (ct ->> 'party_id')::uuid;  v_amt := (ct ->> 'amount_minor')::bigint;
    if v_amt is null or v_amt < 0 then raise exception 'Contribution cannot be negative' using errcode = '22023'; end if;
    if v_amt = 0 then continue; end if;
    perform _check_party(v_party, p_group);
    insert into contributions (expense_id, party_id, amount_minor) values (p_expense, v_party, v_amt);
    v_contrib := v_contrib + v_amt;
  end loop;
  if v_contrib > v_total then
    raise exception 'Contributions (%) exceed the expense total (%)', fmt_pkr(v_contrib), fmt_pkr(v_total) using errcode = '22023';
  end if;
  update expenses set total_minor = v_total, unpaid_minor = v_total - v_contrib where id = p_expense;
  perform _derive_debts(p_expense);
end $$;

create function _expense_snapshot(p_expense uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'title', e.title, 'total_minor', e.total_minor, 'unpaid_minor', e.unpaid_minor, 'version', e.version,
    'status', e.status, 'category', e.category, 'notes', e.notes,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'quantity', i.quantity, 'unit_minor', i.unit_minor,
              'allocations', (select jsonb_object_agg(a.party_id, a.amount_minor) from item_allocations a where a.item_id = i.id))
              order by i.position, i.id), '[]') from expense_items i where i.expense_id = e.id),
    'shares', (select coalesce(jsonb_object_agg(s.party_id, s.share_minor), '{}') from expense_shares s where s.expense_id = e.id),
    'contributions', (select coalesce(jsonb_object_agg(c.party_id, c.amount_minor), '{}') from contributions c where c.expense_id = e.id))
  from expenses e where e.id = p_expense $$;

create function _expense_parties(p_expense uuid) returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p), '{}') from (
    select party_id p from expense_shares where expense_id = p_expense
    union select party_id from contributions where expense_id = p_expense) q $$;

-- ------------------------------------------------------------------ create
create function create_expense(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_op uuid := (p ->> 'client_op_id')::uuid; v_id uuid; v_group uuid := nullif(p ->> 'group_id', '')::uuid;
  v_parties uuid[]; d record;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if v_op is null then raise exception 'client_op_id is required' using errcode = '22023'; end if;
  if v_group is not null and not is_group_member(v_group) then
    raise exception 'You are not a member of this group' using errcode = '42501';
  end if;
  insert into expenses (created_by, client_op_id, group_id, title, notes, category, expense_date, expense_time,
                        total_minor, unpaid_minor, reminder_interval_h, reminder_max, receipt_path)
  values (auth.uid(), v_op, v_group, btrim(p ->> 'title'), p ->> 'notes', p ->> 'category',
          coalesce((p ->> 'expense_date')::date, current_date), (p ->> 'expense_time')::time, 0, 0,
          coalesce((p ->> 'reminder_interval_hours')::int, 24),
          coalesce((p ->> 'reminder_max')::int, (select value::int from app_settings where key = 'reminder_default_max')),
          p ->> 'receipt_path')
  on conflict (created_by, client_op_id) do nothing returning id into v_id;
  if v_id is null then      -- retry of an operation that already succeeded: return it, create nothing
    return (select id from expenses where created_by = auth.uid() and client_op_id = v_op);
  end if;
  perform _write_expense_body(v_id, p, v_group);
  v_parties := _expense_parties(v_id);
  if not exists (select 1 from unnest(v_parties) x where controls_party(x)) then
    raise exception 'You must take part in the expense you record' using errcode = '42501';
  end if;
  for d in select db.debtor_party, db.creditor_party, db.amount_minor, pa.user_id, cr.display_name cname
           from debts db join parties pa on pa.id = db.debtor_party join parties cr on cr.id = db.creditor_party
           where db.expense_id = v_id and pa.user_id is not null loop
    perform _notify(d.user_id, 'new_debt', (p ->> 'title'), 'You owe ' || fmt_pkr(d.amount_minor) || ' to ' || d.cname,
                    jsonb_build_object('expense_id', v_id));
  end loop;
  perform _log('EXPENSE_CREATED', 'expense', v_id, v_id, v_group, null, _expense_snapshot(v_id), null, _audience(v_parties));
  return v_id;
end $$;

-- ------------------------------------------------------------------ edit
-- Metadata, reminder settings and per-person reminder flags can always change. Changing amounts or
-- allocations is refused once any confirmed repayment or adjustment touches the expense's debts: those
-- corrections must go through payment reversal (reverse_payment) or adjust_debt, so history is never rewritten.
create function revise_expense(p_expense uuid, p_expected_version int, p_reason text, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare e expenses; v_before jsonb; v_financial boolean := p ? 'items'; v_group uuid;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required to edit an expense' using errcode = '22023'; end if;
  select * into e from expenses where id = p_expense for update;
  if not found or e.created_by <> auth.uid() then raise exception 'Only the creator can edit this expense' using errcode = '42501'; end if;
  if e.status <> 'active' then raise exception 'A voided expense cannot be edited' using errcode = '22023'; end if;
  if e.version <> p_expected_version then
    raise exception 'This expense was changed by someone else. Reload and try again.' using errcode = '40001';
  end if;
  v_before := _expense_snapshot(p_expense);
  v_group := e.group_id;
  if v_financial then
    if exists (select 1 from repayment_allocations ra join debts d on d.id = ra.debt_id where d.expense_id = p_expense)
       or exists (select 1 from debt_adjustments da join debts d on d.id = da.debt_id where d.expense_id = p_expense) then
      raise exception 'Confirmed payments exist for this expense. Reverse them or use an adjustment before changing amounts.' using errcode = '55000';
    end if;
    delete from debts where expense_id = p_expense;          -- cascades reminder schedules/attempts
    delete from contributions where expense_id = p_expense;
    delete from expense_shares where expense_id = p_expense;
    delete from item_allocations where item_id in (select id from expense_items where expense_id = p_expense);
    delete from expense_items where expense_id = p_expense;
  end if;
  update expenses set
      title = coalesce(btrim(p ->> 'title'), title), notes = coalesce(p ->> 'notes', notes),
      category = coalesce(p ->> 'category', category),
      expense_date = coalesce((p ->> 'expense_date')::date, expense_date),
      reminder_interval_h = coalesce((p ->> 'reminder_interval_hours')::int, reminder_interval_h),
      reminder_max = coalesce((p ->> 'reminder_max')::int, reminder_max),
      version = version + 1
   where id = p_expense;
  if v_financial then
    perform _write_expense_body(p_expense, p, v_group);
    if not exists (select 1 from unnest(_expense_parties(p_expense)) x where controls_party(x)) then
      raise exception 'You must take part in the expense you record' using errcode = '42501';
    end if;
  else
    update reminder_schedules rs set interval_hours = x.reminder_interval_h, max_count = x.reminder_max,
           next_due_at = least(rs.next_due_at, now() + make_interval(hours => x.reminder_interval_h))
      from debts d join expenses x on x.id = d.expense_id where rs.debt_id = d.id and d.expense_id = p_expense;
    if p ? 'remind' then
      update expense_shares s set remind = coalesce((p -> 'remind' ->> s.party_id::text)::boolean, s.remind) where s.expense_id = p_expense;
    end if;
  end if;
  perform _log(case when v_financial then 'EXPENSE_EDITED' else 'EXPENSE_DETAILS_EDITED' end, 'expense', p_expense, p_expense, v_group,
               v_before, _expense_snapshot(p_expense), p_reason, _audience(_expense_parties(p_expense)));
  return e.version + 1;
end $$;

create function set_share_reminders(p_expense uuid, p_party uuid, p_enabled boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from expenses where id = p_expense and created_by = auth.uid() and status = 'active') then
    raise exception 'Only the creator can change reminders' using errcode = '42501';
  end if;
  update expense_shares set remind = p_enabled where expense_id = p_expense and party_id = p_party;
  if not found then raise exception 'Not a participant' using errcode = '22023'; end if;
  perform _log('REMINDER_PREFERENCE_CHANGED', 'expense', p_expense, p_expense, null, null,
               jsonb_build_object('party', p_party, 'remind', p_enabled), null, _audience(array[p_party]));
end $$;

-- ------------------------------------------------------------------ void
create function void_expense(p_expense uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare e expenses;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required' using errcode = '22023'; end if;
  select * into e from expenses where id = p_expense for update;
  if not found or e.created_by <> auth.uid() then raise exception 'Only the creator can void this expense' using errcode = '42501'; end if;
  if e.status = 'voided' then raise exception 'Already voided' using errcode = '22023'; end if;
  if exists (select 1 from repayment_allocations ra join debts d on d.id = ra.debt_id where d.expense_id = p_expense group by ra.debt_id having sum(ra.amount_minor) > 0) then
    raise exception 'Confirmed payments exist. Reverse them first, then void.' using errcode = '55000';
  end if;
  update expenses set status = 'voided', voided_at = now(), void_reason = p_reason, version = version + 1 where id = p_expense;
  delete from reminder_schedules where debt_id in (select id from debts where expense_id = p_expense);
  perform _log('EXPENSE_VOIDED', 'expense', p_expense, p_expense, e.group_id, _expense_snapshot(p_expense), null, p_reason,
               _audience(_expense_parties(p_expense)));
  perform _notify(pa.user_id, 'expense_voided', e.title || ' was voided', p_reason, jsonb_build_object('expense_id', p_expense))
     from parties pa where pa.id = any (_expense_parties(p_expense)) and pa.user_id is not null;
end $$;
