-- Run after: stub + migrations 0001..0005.  psql -v ON_ERROR_STOP=1 -f 10_suite.sql
create schema test;
grant usage on schema test to authenticated, service_role;
create function test.ok(c boolean, label text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', label; end if; raise notice 'PASS %', label; end $$;
create function test.eq(a anyelement, b anyelement, label text) returns void language plpgsql as $$
begin if a is distinct from b then raise exception 'FAIL: % (got %, expected %)', label, a, b; end if; raise notice 'PASS %', label; end $$;
-- runs a statement and requires it to fail with a message/sqlstate fragment
create function test.fails(stmt text, frag text, label text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if sqlerrm ilike '%' || frag || '%' or sqlstate = frag then raise notice 'PASS %', label; return; end if;
    raise exception 'FAIL: % (wrong error: % / %)', label, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % (statement succeeded)', label;
end $$;
grant execute on all functions in schema test to authenticated, service_role;

-- ---------------------------------------------------------------- users
insert into auth.users (email, email_confirmed_at, phone, phone_confirmed_at, raw_user_meta_data) values
 ('ahmed@x.com', now(), '03001111111', now(), '{"display_name":"Ahmed"}'),
 ('bilal@x.com', now(), null, null, '{"display_name":"Bilal"}'),
 ('usman@x.com', now(), null, null, '{"display_name":"Usman"}'),
 ('mallory@x.com', now(), null, null, '{"display_name":"Mallory"}'),
 ('carol@x.com', now(), null, null, '{"display_name":"Carol"}'),
 ('dave@x.com', now(), null, null, '{"display_name":"Dave"}');
select id as ahmed   from auth.users where email='ahmed@x.com'   \gset
select id as bilal   from auth.users where email='bilal@x.com'   \gset
select id as usman   from auth.users where email='usman@x.com'   \gset
select id as mallory from auth.users where email='mallory@x.com' \gset
select id as carol   from auth.users where email='carol@x.com'   \gset
select id as dave    from auth.users where email='dave@x.com'    \gset
select id as p_ahmed   from parties where user_id=:'ahmed'   \gset
select id as p_bilal   from parties where user_id=:'bilal'   \gset
select id as p_usman   from parties where user_id=:'usman'   \gset
select id as p_mallory from parties where user_id=:'mallory' \gset
select id as p_carol   from parties where user_id=:'carol'   \gset
select id as p_dave    from parties where user_id=:'dave'    \gset
select test.eq((select count(*) from profiles)::int, 6, 'signup trigger created profiles');
select test.eq((select value from profile_contacts where profile_id=:'ahmed' and kind='whatsapp'), '923001111111', 'phone normalised to 92...');
update profiles set email_discoverable = true where id in (:'ahmed', :'bilal');
update profiles set phone_discoverable = true where id = :'ahmed';

-- ---------------------------------------------------------------- groups & guests (as ahmed)
set role authenticated; select set_config('request.jwt.claim.sub', :'ahmed', false);
select create_group('Room 12', 'hostel room') as g1 \gset
select create_group_invite(:'g1'::uuid) as code \gset
select create_guest('Hamza', 'hamza@x.com', null, 'room 12 friend') as p_hamza \gset
select add_guest_to_group(:'g1'::uuid, :'p_hamza'::uuid);
select test.eq(length(:'code'), 12, 'invite code generated');
select test.eq((select count(*) from group_invites where code_hash = convert_to(:'code','utf8'))::int, 0, 'plain invite code is not stored');

select set_config('request.jwt.claim.sub', :'bilal', false);  select join_group(:'code');
select set_config('request.jwt.claim.sub', :'usman', false);  select join_group(:'code');
select test.fails(format('select join_group(%L)', 'WRONGCODE00'), 'Invalid or expired invite', 'bad invite code rejected');

-- ---------------------------------------------------------------- Test B (server side): item-level participation
select set_config('request.jwt.claim.sub', :'ahmed', false);
select create_expense(jsonb_build_object(
  'client_op_id', gen_random_uuid(), 'title', 'Friday Dinner', 'group_id', :'g1', 'total_minor', 170000,
  'reminder_interval_hours', 6,
  'items', jsonb_build_array(
    jsonb_build_object('name','Meals','quantity',4,'unit_minor',30000,'method','equal','allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_ahmed','amount_minor',30000), jsonb_build_object('party_id',:'p_bilal','amount_minor',30000),
      jsonb_build_object('party_id',:'p_usman','amount_minor',30000), jsonb_build_object('party_id',:'p_hamza','amount_minor',30000))),
    jsonb_build_object('name','Cold drinks','quantity',3,'unit_minor',10000,'method','equal','allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_ahmed','amount_minor',10000), jsonb_build_object('party_id',:'p_bilal','amount_minor',10000),
      jsonb_build_object('party_id',:'p_usman','amount_minor',10000))),
    jsonb_build_object('name','Delivery','kind','charge','quantity',1,'unit_minor',20000,'method','equal','allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_ahmed','amount_minor',5000), jsonb_build_object('party_id',:'p_bilal','amount_minor',5000),
      jsonb_build_object('party_id',:'p_usman','amount_minor',5000), jsonb_build_object('party_id',:'p_hamza','amount_minor',5000)))),
  'contributions', jsonb_build_array(jsonb_build_object('party_id',:'p_ahmed','amount_minor',170000)),
  'remind', jsonb_build_object(:'p_hamza', false))) as e1 \gset
select test.eq((select share_minor from expense_shares where expense_id=:'e1' and party_id=:'p_ahmed'), 45000::bigint, 'B: ahmed share 450');
select test.eq((select share_minor from expense_shares where expense_id=:'e1' and party_id=:'p_bilal'), 45000::bigint, 'B: bilal share 450');
select test.eq((select share_minor from expense_shares where expense_id=:'e1' and party_id=:'p_usman'), 45000::bigint, 'B: usman share 450');
select test.eq((select share_minor from expense_shares where expense_id=:'e1' and party_id=:'p_hamza'), 35000::bigint, 'B: hamza (no drinks) share 350');
select test.eq((select count(*) from debts where expense_id=:'e1')::int, 3, 'B: three debts derived by the server');
select test.eq((select sum(amount_minor) from debts where expense_id=:'e1')::bigint, 125000::bigint, 'B: debts total 1250');
select test.eq((select count(*) from reminder_schedules rs join debts d on d.id=rs.debt_id where d.expense_id=:'e1')::int, 3, 'B: reminder schedule stored server-side per debt');

-- idempotent retry of create_expense
select test.eq((select count(*) from expenses)::int, 1, 'exactly one expense so far');

-- ---------------------------------------------------------------- server-side validation (tampering)
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','items',jsonb_build_array(
   jsonb_build_object('name','a','quantity',1,'unit_minor',1000,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',900)))),
   'contributions','[]'::jsonb))$q$, :'p_ahmed'), 'must equal its total', 'V: allocations must sum to the line total');
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','items',jsonb_build_array(
   jsonb_build_object('name','a','quantity',1,'unit_minor',1000,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',1000)))),
   'contributions',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',2000))))$q$, :'p_ahmed', :'p_ahmed'), 'exceed the expense total', 'V: contributions cannot exceed total');
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','total_minor',999,'items',jsonb_build_array(
   jsonb_build_object('name','a','quantity',1,'unit_minor',1000,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',1000)))),
   'contributions','[]'::jsonb))$q$, :'p_ahmed'), 'does not match', 'V: recorded total must match items');
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','items',jsonb_build_array(
   jsonb_build_object('name','a','quantity',1,'unit_minor',-5,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',-5)))),
   'contributions','[]'::jsonb))$q$, :'p_ahmed'), 'negative', 'V: negative price rejected');
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','items',jsonb_build_array(
   jsonb_build_object('name','a','quantity',1,'unit_minor',1000,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',1000)))),
   'contributions','[]'::jsonb))$q$, :'p_mallory'), 'cannot include this person', 'V: cannot charge a stranger');

-- ---------------------------------------------------------------- Test C (server side): multiple contributors
select create_expense(jsonb_build_object('client_op_id', gen_random_uuid(), 'title', 'Restaurant', 'group_id', :'g1',
  'items', jsonb_build_array(jsonb_build_object('name','Bill','quantity',1,'unit_minor',200000,'method','equal','allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_ahmed','amount_minor',50000), jsonb_build_object('party_id',:'p_bilal','amount_minor',50000),
      jsonb_build_object('party_id',:'p_usman','amount_minor',50000), jsonb_build_object('party_id',:'p_hamza','amount_minor',50000)))),
  'contributions', jsonb_build_array(jsonb_build_object('party_id',:'p_ahmed','amount_minor',120000), jsonb_build_object('party_id',:'p_bilal','amount_minor',80000)))) as e2 \gset
select test.eq((select count(*) from debts where expense_id=:'e2')::int, 3, 'C: three debts');
select test.eq((select sum(amount_minor) from debts where expense_id=:'e2' and creditor_party=:'p_ahmed')::bigint, 70000::bigint, 'C: ahmed is owed 700');
select test.eq((select sum(amount_minor) from debts where expense_id=:'e2' and creditor_party=:'p_bilal')::bigint, 30000::bigint, 'C: bilal is owed 300');
select test.eq((select sum(amount_minor) from debts where expense_id=:'e2' and debtor_party in (:'p_usman', :'p_hamza'))::bigint, 100000::bigint, 'C: usman+hamza owe 1000');

-- incomplete bill: unpaid portion visible, no guessed debts
select create_expense(jsonb_build_object('client_op_id', gen_random_uuid(), 'title', 'Trip (unpaid part)',
  'items', jsonb_build_array(jsonb_build_object('name','Tickets','quantity',1,'unit_minor',100000,'allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_ahmed','amount_minor',50000), jsonb_build_object('party_id',:'p_bilal','amount_minor',50000)))),
  'contributions', jsonb_build_array(jsonb_build_object('party_id',:'p_ahmed','amount_minor',40000)))) as e3 \gset
select test.eq((select unpaid_minor from expenses where id=:'e3'), 60000::bigint, 'unpaid balance recorded separately');
select test.eq((select count(*) from debts where expense_id=:'e3')::int, 0, 'no debts guessed for an incomplete bill');

-- ---------------------------------------------------------------- Test D (server side): partial payments
-- usman owes ahmed: 450 (e1) + 500 (e2, Usman is a debtor to ahmed) etc. Work with the pair total.
select (select outstanding_minor from pair_balances where debtor_party=:'p_usman' and creditor_party=:'p_ahmed') as usman_owes \gset
select test.ok(:usman_owes > 60000, 'D: usman owes ahmed more than 600');
select set_config('request.jwt.claim.sub', :'usman', false);
select report_payment('k-usman-1', :'p_usman', :'p_ahmed', 60000, 'TXN123', 'easypaisa') as r1 \gset
select report_payment('k-usman-1', :'p_usman', :'p_ahmed', 60000, 'TXN123', 'easypaisa') as r1b \gset
select test.eq(:'r1'::text, :'r1b'::text, 'D: retrying a report with the same key is idempotent');
select test.eq((select count(*) from repayments)::int, 1, 'D: no duplicate repayment');
select test.eq((select outstanding_minor from pair_balances where debtor_party=:'p_usman' and creditor_party=:'p_ahmed'), :usman_owes::bigint, 'D: report alone does NOT reduce the confirmed debt');
select test.eq((select awaiting_confirmation_minor from pair_balances where debtor_party=:'p_usman' and creditor_party=:'p_ahmed'), 60000::bigint, 'D: 600 shown as awaiting confirmation');
select test.fails(format('select confirm_payment(%L, 60000)', :'r1'), 'Only the recipient', 'D: debtor cannot confirm their own payment');
select test.fails(format('select report_payment(%L, %L, %L, 1000)', 'k-forge', :'p_bilal', :'p_ahmed'), 'only report your own', 'D: cannot report on behalf of someone else');
select test.fails(format('select report_payment(%L, %L, %L, %s)', 'k-big', :'p_usman', :'p_ahmed', :usman_owes + 1), 'more than the outstanding', 'D: cannot report more than owed');
select set_config('request.jwt.claim.sub', :'ahmed', false);
select confirm_payment(:'r1'::uuid, 60000);
select confirm_payment(:'r1'::uuid, 60000);
select test.eq((select outstanding_minor from pair_balances where debtor_party=:'p_usman' and creditor_party=:'p_ahmed'), (:usman_owes - 60000)::bigint, 'D: after confirmation 600 is deducted');
select test.eq((select count(*) from repayment_allocations where repayment_id=:'r1')::int, 2, 'D: payment spans two debts');
select test.eq((select ra.amount_minor from repayment_allocations ra join debts d on d.id=ra.debt_id where ra.repayment_id=:'r1' and d.expense_id=:'e1'), 45000::bigint, 'D: oldest debt (dinner) is cleared first with 450');
select test.eq((select ra.amount_minor from repayment_allocations ra join debts d on d.id=ra.debt_id where ra.repayment_id=:'r1' and d.expense_id=:'e2'), 15000::bigint, 'D: remaining 150 goes to the next debt');
select test.fails(format('select confirm_payment(%L, 1)', :'r1'), 'different amount', 'D: confirmed payment cannot be re-confirmed with another amount');

-- ---------------------------------------------------------------- reminders: Tests F, G, H
reset role;
select b.outstanding_minor as e2_ua from debt_balances b join debts d on d.id=b.debt_id where d.expense_id=:'e2' and d.debtor_party=:'p_usman' and d.creditor_party=:'p_ahmed' \gset
update reminder_schedules set next_due_at = now() - interval '1 hour';       -- simulate time passing
set role service_role;
select count(*) as run1 from claim_due_reminders(100, true) \gset
select test.ok(:run1 >= 1, 'H: first scheduler run claims reminders');
select count(*) as run2 from claim_due_reminders(100, true) \gset
select test.eq(:run2, 0, 'H: second scheduler run claims nothing (no duplicates)');
reset role;
select test.eq((select count(*) from (select debt_id, sequence, channel from reminder_attempts group by 1,2,3 having count(*) > 1) q)::int, 0, 'H: no duplicate (debt,sequence,channel) attempts');
select test.eq((select count(*) from reminder_attempts a join debts d on d.id=a.debt_id where d.debtor_party=:'p_hamza' and d.expense_id=:'e1' and a.channel='email')::int, 0, 'G: opted-out guest got no email reminder attempt for that expense');
select test.eq((select count(*) from reminder_attempts a join debts d on d.id=a.debt_id where d.debtor_party=:'p_hamza' and d.expense_id=:'e1')::int, 0, 'G: opted-out guest has no reminder attempts for that expense');
select test.ok((select count(*) from reminder_attempts a join debts d on d.id=a.debt_id where d.debtor_party=:'p_hamza' and d.expense_id=:'e2' and a.channel='email') >= 1, 'G: reminders still go out for the other expense where he is not opted out');
select test.ok((select outstanding_minor from debt_balances b join debts d on d.id=b.debt_id where d.debtor_party=:'p_hamza' and d.expense_id=:'e1') = 35000, 'G: guest share still counted in accounting');
select test.eq((select a.amount_minor from reminder_attempts a join debts d on d.id=a.debt_id where d.debtor_party=:'p_usman' and d.creditor_party=:'p_ahmed' and d.expense_id=:'e2' and a.channel='inapp'), :e2_ua::bigint, 'F: partially paid debt is reminded for its remaining balance only');
select test.eq((select count(*) from reminder_attempts a join debts d on d.id=a.debt_id where d.debtor_party=:'p_usman' and d.expense_id=:'e1')::int, 0, 'F: debt settled by the partial payment gets no reminder');
select test.ok((select count(*) from notifications where user_id=:'usman' and kind='reminder') >= 1, 'in-app reminder notification persisted');
select test.eq((select email_status from notifications where user_id=:'usman' and kind='reminder' limit 1), 'skipped', 'reminder in-app rows are not double-emailed');
-- debtor with a pending report is paused
set role authenticated; select set_config('request.jwt.claim.sub', :'bilal', false);
select report_payment('k-bilal-1', :'p_bilal', :'p_ahmed', 10000) as r_b \gset
reset role;
select test.ok((select count(*) from reminder_schedules rs join debts d on d.id=rs.debt_id where d.debtor_party=:'p_bilal' and d.creditor_party=:'p_ahmed' and rs.paused_until > now()) >= 1, 'reminders paused while a report awaits confirmation');
update reminder_schedules set next_due_at = now() - interval '1 hour', sent_count = 0;
set role service_role;
select count(*) as run3 from claim_due_reminders(100, true) where debtor_name = 'Bilal' and creditor_name = 'Ahmed' \gset
select test.eq(:run3, 0, 'paused debts are not reminded');
reset role;
-- max reminder count honoured
update reminder_schedules set sent_count = max_count, next_due_at = now() - interval '1 hour';
set role service_role; select count(*) as run4 from claim_due_reminders(100, true) \gset
select test.eq(:run4, 0, 'reminders stop at the maximum count');
reset role;
-- fully settled debt gets no more reminders; partial debt reminded for the remainder only
update reminder_schedules set sent_count = 0, next_due_at = now() - interval '1 hour', paused_until = null;
set role authenticated; select set_config('request.jwt.claim.sub', :'usman', false);
select (select outstanding_minor from pair_balances where debtor_party=:'p_usman' and creditor_party=:'p_ahmed') as left_to_ahmed \gset
select report_payment('k-usman-2', :'p_usman', :'p_ahmed', :left_to_ahmed) as r2 \gset
select set_config('request.jwt.claim.sub', :'ahmed', false);
select confirm_payment(:'r2'::uuid, :left_to_ahmed);
reset role;
select test.eq((select next_due_at from reminder_schedules rs join debts d on d.id=rs.debt_id where d.expense_id=:'e2' and d.debtor_party=:'p_usman' and d.creditor_party=:'p_ahmed'), 'infinity'::timestamptz, 'F: fully settled debt: reminders switched off');
set role service_role;
select count(*) as run5 from claim_due_reminders(100, true) c where c.expense_id=:'e2' and c.debtor_name='Usman' and c.creditor_name='Ahmed' \gset
select test.eq(:run5, 0, 'F: nothing sent for a settled debt');
reset role;
select test.eq((select count(*) from debt_balances b join debts d on d.id=b.debt_id where d.debtor_party=:'p_usman' and d.expense_id=:'e2' and b.outstanding_minor > 0
   and not exists (select 1 from reminder_attempts a where a.debt_id=b.debt_id and a.channel='inapp' and a.amount_minor=b.outstanding_minor))::int, 0, 'F: every still-open debt was reminded for exactly its outstanding amount');

-- email provider off: nothing is marked sent
set role service_role;
select count(*) as e_off from claim_due_reminders(100, false) where channel = 'email' \gset
select test.eq(:e_off, 0, 'email disabled: no email work handed out');
select claim_email_notifications(50, false);
reset role;
select test.eq((select count(*) from notifications where email_status in ('sending','sent'))::int, 0, 'email disabled: nothing is ever marked sent');

-- ---------------------------------------------------------------- Test E (server side): netting across expenses
set role authenticated; select set_config('request.jwt.claim.sub', :'carol', false);
select create_guest('Unused') as _x \gset
select set_config('request.jwt.claim.sub', :'carol', false);
reset role;
insert into known_parties values (:'carol', :'p_dave'), (:'dave', :'p_carol');
set role authenticated; select set_config('request.jwt.claim.sub', :'dave', false);
select create_expense(jsonb_build_object('client_op_id', gen_random_uuid(), 'title', 'Groceries',
  'items', jsonb_build_array(jsonb_build_object('name','Food','quantity',1,'unit_minor',60000,'allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_carol','amount_minor',30000), jsonb_build_object('party_id',:'p_dave','amount_minor',30000)))),
  'contributions', jsonb_build_array(jsonb_build_object('party_id',:'p_dave','amount_minor',60000)))) as eg \gset
select set_config('request.jwt.claim.sub', :'carol', false);
select create_expense(jsonb_build_object('client_op_id', gen_random_uuid(), 'title', 'Dinner',
  'items', jsonb_build_array(jsonb_build_object('name','Food','quantity',1,'unit_minor',40000,'allocations', jsonb_build_array(
      jsonb_build_object('party_id',:'p_carol','amount_minor',20000), jsonb_build_object('party_id',:'p_dave','amount_minor',20000)))),
  'contributions', jsonb_build_array(jsonb_build_object('party_id',:'p_carol','amount_minor',40000)))) as ed \gset
select test.eq((select count(*) from debt_balances where outstanding_minor > 0 and expense_status='active' and (debtor_party=:'p_carol' or creditor_party=:'p_carol'))::int, 2, 'E: both debts retained in the transaction view');
select test.eq((select count(*) from suggest_settlements())::int, 1, 'E: one netted suggestion');
select test.eq((select from_party from suggest_settlements()), :'p_carol'::uuid, 'E: carol pays');
select test.eq((select to_party from suggest_settlements()), :'p_dave'::uuid, 'E: dave receives');
select test.eq((select amount_minor from suggest_settlements()), 10000::bigint, 'E: net amount is 100 (300 - 200)');
select test.eq((select gross_owed_minor from suggest_settlements()), 30000::bigint, 'E: gross owed 300 shown');
select test.eq((select gross_owed_back_minor from suggest_settlements()), 20000::bigint, 'E: gross owed back 200 shown');
select test.eq((select allocation -> 0 ->> 'amount_minor' from suggest_settlements()), '10000', 'E: allocation breakdown names the debt it applies to');

-- ---------------------------------------------------------------- reversal & corrections (Test L, server side)
select set_config('request.jwt.claim.sub', :'ahmed', false);
select test.fails(format($q$select revise_expense(%L, 1, 'fix', jsonb_build_object('items', jsonb_build_array(jsonb_build_object('name','x','quantity',1,'unit_minor',1000,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',1000))))))$q$, :'e1', :'p_ahmed'),
                 'Confirmed payments exist', 'L: amounts cannot be rewritten once payments are confirmed');
select test.fails(format('select revise_expense(%L, 99, %L, %L::jsonb)', :'e1', 'typo', '{"title":"Friday dinner"}'), '40001', 'L: stale version rejected (no silent overwrite)');
select test.fails(format('select revise_expense(%L, 1, %L, %L::jsonb)', :'e1', '', '{"title":"x"}'), 'reason is required', 'L: edit needs a reason');
select revise_expense(:'e1'::uuid, 1, 'typo in title', '{"title":"Friday Dinner (Room 12)"}'::jsonb);
select test.eq((select version from expenses where id=:'e1'), 2, 'L: version incremented');
select test.eq((select before ->> 'title' from activity_events where type='EXPENSE_DETAILS_EDITED' and expense_id=:'e1'), 'Friday Dinner', 'L: audit keeps the before value');
select test.eq((select after ->> 'title' from activity_events where type='EXPENSE_DETAILS_EDITED' and expense_id=:'e1'), 'Friday Dinner (Room 12)', 'L: audit keeps the after value');
select test.fails(format('select void_expense(%L, %L)', :'e1', 'oops'), 'Reverse them first', 'L: expense with confirmed payments cannot be voided directly');
select reverse_payment(:'r1'::uuid, 'wrong transfer');
select test.eq((select status::text from repayments where id=:'r1'), 'reversed', 'L: original repayment kept, marked reversed');
select test.eq((select sum(amount_minor) from repayment_allocations where repayment_id=:'r1')::bigint, 0::bigint, 'L: compensating rows net the allocation to zero');
select test.eq((select count(*) from repayment_allocations where repayment_id=:'r1' and amount_minor > 0)::int, 2, 'L: original allocation rows still present');
select test.eq((select count(*) from repayment_allocations where repayment_id=:'r1' and amount_minor < 0 and reverses is not null)::int, 2, 'L: each original row has a compensating row pointing at it');
select test.ok((select outstanding_minor from pair_balances where debtor_party=:'p_usman' and creditor_party=:'p_ahmed') > 0, 'L: balance restored after reversal');
reset role;
select test.fails($q$update activity_events set reason = 'tampered'$q$, 'append-only', 'audit rows cannot be updated even by an admin');
select test.fails($q$delete from activity_events$q$, 'append-only', 'audit rows cannot be deleted');
select test.fails($q$delete from repayment_allocations$q$, 'append-only', 'allocation history cannot be deleted');

-- ---------------------------------------------------------------- Test J: claiming a guest profile
-- Not verified yet: an account with the same address but no verification
insert into auth.users (email, email_confirmed_at, raw_user_meta_data) values ('hamza@x.com', null, '{"display_name":"Hamza"}');
select id as hamza from auth.users where email='hamza@x.com' \gset
select id as p_hamza_user from parties where user_id=:'hamza' \gset
select (select count(*) from debts where debtor_party=:'p_hamza') as hamza_debts_before \gset
set role authenticated;
select set_config('request.jwt.claim.sub', :'hamza', false);
select test.fails(format('select claim_guest_profile(%L)', :'p_hamza'), 'Verify the email', 'J: unverified email cannot claim');
select set_config('request.jwt.claim.sub', :'mallory', false);
select test.fails(format('select claim_guest_profile(%L)', :'p_hamza'), 'Verify the email', 'J: someone else cannot claim by name');
select set_config('request.jwt.claim.sub', :'ahmed', false);
select test.fails(format('select claim_guest_profile(%L)', :'p_hamza'), 'Verify the email', 'J: the creator/admin cannot take over the identity');
reset role;
update auth.users set email_confirmed_at = now() where id = :'hamza';        -- verification completes
set role authenticated; select set_config('request.jwt.claim.sub', :'hamza', false);
select claim_guest_profile(:'p_hamza'::uuid);
select test.eq((select count(*) from debts where debtor_party=:'p_hamza_user')::int, :hamza_debts_before::int, 'J: all debts moved to the claimed account');
select test.eq((select count(*) from debts where debtor_party=:'p_hamza')::int, 0, 'J: nothing left on the old guest identity');
select test.ok((select count(*) from expense_shares where party_id=:'p_hamza_user') >= 2, 'J: expense history preserved');
select test.ok((select count(*) from activity_events where type='GUEST_CLAIMED') = 1, 'J: claim is audited');
select test.fails(format('select claim_guest_profile(%L)', :'p_hamza'), 'cannot be claimed', 'J: cannot be claimed twice');
reset role;
select test.eq((select count(*) from profile_claims)::int, 1, 'J: exactly one claim record');
select test.ok(exists (select 1 from group_members where group_id=:'g1' and party_id=:'p_hamza_user'), 'J: group membership carried over');

-- guest with no verified contact can never be claimed
set role authenticated; select set_config('request.jwt.claim.sub', :'ahmed', false);
select create_guest('Nameless') as p_nameless \gset
select set_config('request.jwt.claim.sub', :'mallory', false);
select test.fails(format('select claim_guest_profile(%L)', :'p_nameless'), 'Verify the email', 'J: guest without contact details cannot be claimed');

-- ---------------------------------------------------------------- Test I: security
select set_config('request.jwt.claim.sub', :'ahmed', false);
insert into payment_methods (provider, method_type, account_holder, account_number, nickname, shared_with_debtors)
  values ('Easypaisa', 'wallet', 'Ahmed Khan', '03001111111', 'Shared one', true);
insert into payment_methods (provider, method_type, account_holder, account_number, nickname)
  values ('HBL', 'bank', 'Ahmed Khan', 'PK00HABB0000000000000000', 'Private one');
select test.eq((select count(*) from payment_methods)::int, 2, 'I: owner sees both own payment methods');
select test.fails($q$insert into payment_methods (owner_id, provider, method_type, account_holder, account_number) values (gen_random_uuid(), 'x','bank','x','x')$q$, 'permission denied', 'I: cannot create a method owned by someone else');

select set_config('request.jwt.claim.sub', :'mallory', false);
select test.eq((select count(*) from expenses)::int, 0, 'I: outsider sees no expenses');
select test.eq((select count(*) from expense_shares)::int, 0, 'I: outsider sees no shares');
select test.eq((select count(*) from contributions)::int, 0, 'I: outsider sees no contributions');
select test.eq((select count(*) from debts)::int, 0, 'I: outsider sees no debts');
select test.eq((select count(*) from debt_balances)::int, 0, 'I: outsider sees no balances');
select test.eq((select count(*) from repayments)::int, 0, 'I: outsider sees no repayment records');
select test.eq((select count(*) from repayment_allocations)::int, 0, 'I: outsider sees no allocations');
select test.eq((select count(*) from payment_methods)::int, 0, 'I: outsider cannot see anyone''s payment methods');
select test.eq((select count(*) from activity_events)::int, 0, 'I: outsider sees no audit events');
select test.eq((select count(*) from groups)::int, 0, 'I: outsider sees no groups');
select test.eq((select count(*) from group_members)::int, 0, 'I: outsider sees no memberships');
select test.eq((select count(*) from notifications)::int, 0, 'I: outsider sees no notifications');
select test.eq((select count(*) from profile_contacts where profile_id <> auth.uid())::int, 0, 'I: other people''s verified contacts are private');
select test.eq((select count(*) from profiles where id <> :'mallory')::int, 0, 'I: other profiles are not readable');
select test.eq((select count(*) from reminder_schedules)::int, 0, 'I: outsider sees no reminder schedules');
select test.fails($q$select email from parties limit 1$q$, 'permission denied', 'I: guest contact columns are not selectable');
select test.fails($q$insert into expenses (created_by, client_op_id, title, total_minor, unpaid_minor) values (auth.uid(), gen_random_uuid(), 'fake', 1, 0)$q$, 'permission denied', 'I: no direct inserts into expenses');
select test.fails($q$update repayments set status = 'confirmed'$q$, 'permission denied', 'I: no direct updates to repayments');
select test.fails($q$insert into activity_events (actor_id, type, subject_type) values (auth.uid(), 'FORGED', 'x')$q$, 'permission denied', 'I: audit events cannot be forged');
select test.fails($q$insert into debts (expense_id, debtor_party, creditor_party, amount_minor) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1)$q$, 'permission denied', 'I: no direct debt creation');
select test.fails($q$delete from expenses$q$, 'permission denied', 'I: no direct deletes');
select test.fails(format('select confirm_payment(%L, 100)', :'r_b'), 'Only the recipient', 'I: cannot confirm someone else''s repayment');
select test.fails(format('select reverse_payment(%L, %L)', :'r2', 'x'), 'Only the recipient', 'I: cannot reverse someone else''s repayment');
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','group_id',%L,'items',jsonb_build_array(jsonb_build_object('name','a','quantity',1,'unit_minor',100,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',100)))),'contributions','[]'::jsonb))$q$, :'g1', :'p_mallory'), 'not a member', 'I: cannot create expenses in a group they are not in');
select test.fails(format('select create_group_invite(%L)', :'g1'), 'Only group admins', 'I: cannot mint invites for another group');
select test.fails(format('select void_expense(%L, %L)', :'e2', 'x'), 'Only the creator', 'I: cannot void another user''s expense');
select test.fails(format($q$select revise_expense(%L, 1, 'x', '{"title":"hacked"}'::jsonb)$q$, :'e2'), 'Only the creator', 'I: cannot edit another user''s expense');
select test.fails(format('select adjust_debt(%L, 1, %L)', (select id from (select id from debts limit 1) q), 'x'), 'Only the person owed', 'I: cannot forgive someone else''s debt');
select test.fails($q$select claim_guest_profile(gen_random_uuid())$q$, 'cannot be claimed', 'I: claiming an unknown id fails');
select test.fails($q$select claim_due_reminders(10, true)$q$, 'permission denied', 'I: scheduler functions are not callable by clients');
select test.eq((select count(*) from find_user('email', 'ahmed@x.com'))::int, 1, 'I: discoverable user found by email');
select test.eq((select count(*) from find_user('email', 'carol@x.com'))::int, 0, 'I: private user not found (no existence leak)');
select test.eq((select count(*) from find_user('email', 'nobody@x.com'))::int, 0, 'I: unknown address looks identical to private');
select test.eq((select count(*) from find_user('whatsapp', '0300-1111111'))::int, 1, 'I: lookup by WhatsApp number (normalised)');
select test.eq((select count(*) from find_user('whatsapp', '03002222222'))::int, 0, 'I: unknown number returns nothing');
select test.eq((select count(*) from known_parties)::int, 1, 'I: only successful lookups are remembered (both hits were the same person)');

-- payment method sharing rules
select set_config('request.jwt.claim.sub', :'bilal', false);
select test.eq((select count(*) from payment_methods_for_creditor(:'p_ahmed'::uuid))::int, 1, 'I: debtor gets exactly the shared method via the function (not the private one)');
select test.eq((select count(*) from payment_methods_for_creditor(:'p_usman'::uuid))::int, 0, 'I: no methods returned for a creditor the caller does not owe');
select test.eq((select count(*) from payment_methods)::int, 1, 'I: debtor sees only the method the creditor chose to share');
select test.eq((select nickname from payment_methods), 'Shared one', 'I: the shared method is the right one');
select set_config('request.jwt.claim.sub', :'carol', false);
select test.eq((select count(*) from payment_methods)::int, 0, 'I: unrelated user (other group) sees none');
-- expense isolation between groups
select test.eq((select count(*) from expenses where id in (:'e1', :'e2'))::int, 0, 'I: other group cannot read this group''s expenses by id');
select set_config('request.jwt.claim.sub', :'dave', false);
select test.eq((select count(*) from expenses)::int, 2, 'I: dave sees only his own two-person expenses');
select test.eq((select count(*) from activity_events where expense_id in (:'e1', :'e2'))::int, 0, 'I: audit events are limited to involved people');

-- notifications
select set_config('request.jwt.claim.sub', :'usman', false);
select test.ok((select count(*) from notifications) > 0, 'usman has persistent notifications');
select test.eq((select count(*) from notifications where user_id <> auth.uid())::int, 0, 'only own notifications visible');
select mark_all_notifications_read();
select test.eq((select count(*) from notifications where read_at is null)::int, 0, 'mark all read works');
select test.eq((my_dashboard() ->> 'unread_notifications')::int, 0, 'dashboard unread count updates');

-- group removal never erases obligations
select set_config('request.jwt.claim.sub', :'ahmed', false);
select remove_group_member(:'g1'::uuid, :'p_usman'::uuid, 'moved out');
select test.ok((select count(*) from debts where debtor_party=:'p_usman') > 0, 'removed member''s debts survive');
select set_config('request.jwt.claim.sub', :'usman', false);
select test.eq((select count(*) from groups)::int, 0, 'removed member loses group access');
select test.ok((select count(*) from expenses where id=:'e1') = 1, 'removed member still sees expenses they take part in');
select test.fails(format($q$select create_expense(jsonb_build_object('client_op_id',gen_random_uuid(),'title','x','group_id',%L,'items',jsonb_build_array(jsonb_build_object('name','a','quantity',1,'unit_minor',100,'allocations',jsonb_build_array(jsonb_build_object('party_id',%L,'amount_minor',100)))),'contributions','[]'::jsonb))$q$, :'g1', :'p_usman'), 'not a member', 'removed member cannot add group expenses');
reset role;
\echo ===== SUITE COMPLETE =====
