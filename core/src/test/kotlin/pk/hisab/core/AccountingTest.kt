package pk.hisab.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private fun R(n: Long) = rupees(n)
private val four = setOf("ahmed", "bilal", "usman", "hamza")

class AllocationAndExpenseTest {

    @Test fun `A equal split of 2000 among four is 500 each`() {
        val spec = ExpenseSpec.quick("e1", "Dinner", "ahmed", R(2000), four, mapOf("ahmed" to R(2000)))
        val c = ExpenseEngine.compute(spec)
        assertEquals(four.associateWith { R(500) }.toSortedMap(), c.shares)
    }

    @Test fun `B item level participation gives 450 450 450 350`() {
        val three = setOf("ahmed", "bilal", "usman")
        val spec = ExpenseSpec(
            "e2", "Friday Dinner", "ahmed", four,
            items = listOf(
                ExpenseItem("i1", "Meals", 4, R(300), AllocationMethod.Equal(four)),
                ExpenseItem("i2", "Cold drinks", 3, R(100), AllocationMethod.Equal(three)),
            ),
            charges = listOf(ExtraCharge("c1", "Delivery", R(200), ChargeMethod.Equal(four))),
            contributions = mapOf("ahmed" to R(1700)),
            recordedTotal = R(1700),
        )
        val c = ExpenseEngine.compute(spec)
        assertEquals(R(450), c.shares["ahmed"])
        assertEquals(R(450), c.shares["bilal"])
        assertEquals(R(450), c.shares["usman"])
        assertEquals(R(350), c.shares["hamza"])
        assertEquals(c.total, c.shares.values.sum())
    }

    @Test fun `C multiple contributors give +700 +300 -500 -500`() {
        val spec = ExpenseSpec.quick("e3", "Restaurant", "ahmed", R(2000), four, mapOf("ahmed" to R(1200), "bilal" to R(800)))
        val net = ExpenseEngine.compute(spec).netPositions
        assertEquals(R(700), net["ahmed"])
        assertEquals(R(300), net["bilal"])
        assertEquals(-R(500), net["usman"])
        assertEquals(-R(500), net["hamza"])
        assertEquals(0L, net.values.sum())
    }

    @Test fun `K rounding reconciles exactly and is deterministic`() {
        val three = setOf("c", "a", "b")
        val r = Allocator.allocate(1_000_001L, AllocationMethod.Equal(three)) // Rs. 10,000.01 / 3
        assertEquals(1_000_001L, r.total)
        // 2 paisa are left over: equal remainders, so the lowest ids (a, b) receive them
        assertEquals(setOf("a", "b"), r.roundingAdjustments.keys)
        assertEquals(mapOf("a" to 333_334L, "b" to 333_334L, "c" to 333_333L), r.shares)
        assertEquals(r, Allocator.allocate(1_000_001L, AllocationMethod.Equal(setOf("b", "a", "c"))))
        // 100 paisa / 3 -> 34,33,33, the extra paisa goes to the lowest id on a tie
        val s = Allocator.allocate(100, AllocationMethod.Equal(three))
        assertEquals(mapOf("a" to 34L, "b" to 33L, "c" to 33L), s.shares)
        assertEquals(mapOf("a" to 1L), s.roundingAdjustments)
    }

    @Test fun `K proportional rounding never loses a paisa`() {
        val r = Allocator.allocate(1_000_00L + 7, AllocationMethod.Proportional(mapOf("a" to 1, "b" to 2, "c" to 4)))
        assertEquals(1_000_07L, r.total)
    }

    @Test fun `quantity allocation weights by units and must match item quantity`() {
        val ok = ExpenseSpec(
            "e4", "Samosas", "ahmed", setOf("ahmed", "bilal"),
            items = listOf(ExpenseItem("i", "Samosa", 5, R(40), AllocationMethod.Quantity(mapOf("ahmed" to 2, "bilal" to 3)))),
            contributions = mapOf("ahmed" to R(200)),
        )
        val c = ExpenseEngine.compute(ok)
        assertEquals(R(80), c.shares["ahmed"]); assertEquals(R(120), c.shares["bilal"])
        val bad = ok.copy(items = listOf(ok.items[0].copy(method = AllocationMethod.Quantity(mapOf("ahmed" to 2, "bilal" to 2)))))
        assertFailsWith<HisabException> { ExpenseEngine.compute(bad) }
    }

    @Test fun `proportional tax follows item subtotals`() {
        val p = setOf("a", "b")
        val spec = ExpenseSpec(
            "e5", "Meal", "a", p,
            items = listOf(
                ExpenseItem("1", "Steak", 1, R(300), AllocationMethod.Equal(setOf("a"))),
                ExpenseItem("2", "Salad", 1, R(100), AllocationMethod.Equal(setOf("b"))),
            ),
            charges = listOf(ExtraCharge("t", "Tax", R(40), ChargeMethod.ProportionalToItems())),
            contributions = mapOf("a" to R(440)),
        )
        val c = ExpenseEngine.compute(spec)
        assertEquals(R(330), c.shares["a"]); assertEquals(R(110), c.shares["b"])
    }

    @Test fun `validation rejects bad input`() {
        val base = ExpenseSpec.quick("e6", "X", "a", R(100), setOf("a", "b"), mapOf("a" to R(100)))
        assertFailsWith<HisabException> { ExpenseEngine.compute(base.copy(recordedTotal = R(99))) }
        assertFailsWith<HisabException> { ExpenseEngine.compute(base.copy(contributions = mapOf("a" to R(101)))) }
        assertFailsWith<HisabException> { ExpenseEngine.compute(base.copy(contributions = mapOf("a" to -1L))) }
        assertFailsWith<HisabException> { ExpenseEngine.compute(base.copy(items = listOf(base.items[0].copy(unitPrice = -5)))) }
        assertFailsWith<HisabException> { ExpenseEngine.compute(base.copy(items = listOf(base.items[0].copy(quantity = 0)))) }
        assertFailsWith<HisabException> { // charging a non-participant
            ExpenseEngine.compute(base.copy(items = listOf(base.items[0].copy(method = AllocationMethod.Equal(setOf("zed"))))))
        }
        assertFailsWith<HisabException> { Allocator.allocate(100, AllocationMethod.Custom(mapOf("a" to 60L, "b" to 30L))) }
    }

    @Test fun `unpaid portion is shown separately and creates no guessed debts`() {
        val spec = ExpenseSpec.quick("e7", "Trip", "a", R(1000), setOf("a", "b"), mapOf("a" to R(400)))
        val c = ExpenseEngine.compute(spec)
        assertEquals(R(600), c.unpaid)
        assertTrue(Ledger().addExpense("a", spec).activeDebts.isEmpty())
    }
}

class LedgerTest {
    private fun dinner(id: String = "dinner") =
        ExpenseSpec.quick(id, "Dinner", "ahmed", R(2000), four, mapOf("ahmed" to R(1200), "bilal" to R(800)))

    /** usman owes ahmed 500 (single expense: bilal pays all) */
    private fun owes1000(): Ledger = Ledger().addExpense(
        "ahmed",
        ExpenseSpec.quick("g", "Groceries", "ahmed", R(2000), setOf("ahmed", "bilal"), mapOf("ahmed" to R(2000))),
    )

    @Test fun `D partial payment only reduces debt once the recipient confirms`() {
        var l = owes1000()
        assertEquals(R(1000), l.outstanding("bilal", "ahmed"))
        l = l.reportPayment("bilal", "r1", "bilal", "ahmed", R(600), "key1")
        val s = l.pairSummary("bilal", "ahmed")
        assertEquals(R(1000), s.original); assertEquals(0L, s.confirmedReceived)
        assertEquals(R(600), s.awaitingConfirmation); assertEquals(R(1000), s.outstanding)
        assertEquals(DebtStatus.AWAITING_CONFIRMATION, l.debtViews().single().status)
        l = l.confirmPayment("ahmed", "r1", R(600))
        val after = l.pairSummary("bilal", "ahmed")
        assertEquals(R(600), after.confirmedReceived); assertEquals(R(400), after.outstanding)
        assertEquals(0L, after.awaitingConfirmation)
        assertEquals(DebtStatus.PARTIALLY_PAID, l.debtViews().single().status)
        l = l.confirmPayment("ahmed", "r1", R(600)) // idempotent
        assertEquals(R(400), l.outstanding("bilal", "ahmed"))
        l = l.reportPayment("bilal", "r2", "bilal", "ahmed", R(400), "key2").confirmPayment("ahmed", "r2", R(400))
        assertEquals(DebtStatus.SETTLED, l.debtViews().single().status)
    }

    @Test fun `recipient may confirm less than reported and reject or dispute with a reason`() {
        var l = owes1000().reportPayment("bilal", "r1", "bilal", "ahmed", R(600), "k1")
        l = l.confirmPayment("ahmed", "r1", R(500))
        assertEquals(R(500), l.outstanding("bilal", "ahmed"))
        l = l.reportPayment("bilal", "r2", "bilal", "ahmed", R(100), "k2").disputePayment("ahmed", "r2", "not received")
        assertEquals(DebtStatus.DISPUTED, l.debtViews().single().status)
        assertFailsWith<HisabException> { l.rejectPayment("ahmed", "r2", " ") }
        l = l.rejectPayment("ahmed", "r2", "no such transfer")
        assertEquals(R(500), l.outstanding("bilal", "ahmed"))
    }

    @Test fun `authorization and idempotency are enforced in the domain`() {
        val l = owes1000()
        assertFailsWith<HisabException> { l.reportPayment("ahmed", "r1", "bilal", "ahmed", R(10), "k") } // not the payer
        val l1 = l.reportPayment("bilal", "r1", "bilal", "ahmed", R(100), "k")
        assertFailsWith<HisabException> { l1.confirmPayment("bilal", "r1", R(100)) } // debtor can't self-confirm
        val again = l1.reportPayment("bilal", "r1b", "bilal", "ahmed", R(100), "k") // retry, same key
        assertEquals(1, again.repayments.size)
        assertFailsWith<HisabException> { l.reportPayment("bilal", "r9", "bilal", "ahmed", R(1001), "z") } // overpay
    }

    @Test fun `E netting suggests 100 from ahmed to bilal while both debts remain`() {
        val groceries = ExpenseSpec.quick("groc", "Groceries", "bilal", R(600), setOf("ahmed", "bilal"), mapOf("bilal" to R(600)))
        val dinner = ExpenseSpec.quick("din", "Dinner", "ahmed", R(400), setOf("ahmed", "bilal"), mapOf("ahmed" to R(400)))
        val l = Ledger().addExpense("bilal", groceries).addExpense("ahmed", dinner)
        assertEquals(R(300), l.outstanding("ahmed", "bilal"))
        assertEquals(R(200), l.outstanding("bilal", "ahmed"))
        assertEquals(2, l.debtViews().size)
        val s = l.suggestSettlements().single()
        assertEquals("ahmed", s.from); assertEquals("bilal", s.to); assertEquals(R(100), s.amount)
        assertEquals(listOf("groc:ahmed>bilal" to R(100)), s.allocation)
        // recording the suggestion is applied to the payer's debts; history is retained
        val after = l.reportPayment("ahmed", "r", "ahmed", "bilal", s.amount, "k").confirmPayment("bilal", "r", s.amount)
        assertEquals(R(200), after.outstanding("ahmed", "bilal"))
        assertEquals(R(200), after.outstanding("bilal", "ahmed"))
        assertTrue(after.suggestSettlements().isEmpty())
    }

    @Test fun `repayments are applied oldest debt first`() {
        val e1 = ExpenseSpec.quick("e1", "One", "ahmed", R(200), setOf("ahmed", "bilal"), mapOf("ahmed" to R(200)))
        val e2 = ExpenseSpec.quick("e2", "Two", "ahmed", R(200), setOf("ahmed", "bilal"), mapOf("ahmed" to R(200)))
        val l = Ledger().addExpense("ahmed", e1).addExpense("ahmed", e2)
            .reportPayment("bilal", "r", "bilal", "ahmed", R(150), "k").confirmPayment("ahmed", "r", R(150))
        val v = l.debtViews().associateBy { it.debt.expenseId }
        assertEquals(DebtStatus.SETTLED, v.getValue("e1").status)
        assertEquals(R(50), v.getValue("e2").confirmedPaid)
    }

    @Test fun `position totals match the underlying debts`() {
        val l = Ledger().addExpense("ahmed", dinner())
        assertEquals(Position(owedToMe = R(700), iOwe = 0), l.position("ahmed"))
        assertEquals(Position(owedToMe = R(300), iOwe = 0), l.position("bilal"))
        assertEquals(Position(0, R(500)), l.position("usman"))
        assertEquals(-R(500), l.position("hamza").net)
        assertEquals(3, l.activeDebts.size)
        assertEquals(R(1000), l.activeDebts.filter { it.debtor in setOf("usman", "hamza") }.sumOf { it.amount })
    }

    @Test fun `L correcting a settled expense keeps confirmed repayments and audit history`() {
        var l = owes1000().reportPayment("bilal", "r1", "bilal", "ahmed", R(1000), "k").confirmPayment("ahmed", "r1", R(1000))
        assertEquals(0L, l.outstanding("bilal", "ahmed"))
        // correction: the bill was really 1,200 -> bilal's share drops to 600; he already paid 1,000
        val fixed = ExpenseSpec.quick("g", "Groceries", "ahmed", R(1200), setOf("ahmed", "bilal"), mapOf("ahmed" to R(1200)))
        val preview = l.previewRevision(fixed).single()
        assertEquals(R(400), preview.overpaid)
        assertFailsWith<HisabException> { l.reviseExpense("ahmed", fixed, 1, "typo in amount") } // must acknowledge
        assertFailsWith<HisabException> { l.reviseExpense("bilal", fixed, 1, "x", true) } // not the creator
        assertFailsWith<HisabException> { l.reviseExpense("ahmed", fixed, 7, "stale", true) } // concurrent edit
        l = l.reviseExpense("ahmed", fixed, 1, "typo in amount", acknowledgeOverpayment = true)
        val rep = l.repayments.single()
        assertEquals(RepaymentStatus.CONFIRMED, rep.status); assertEquals(R(1000), rep.confirmedAmount)
        assertEquals(R(400), l.pairSummary("bilal", "ahmed").unappliedCredit)
        assertEquals(1, l.expenseHistory.size)
        assertEquals(R(2000), l.expenseHistory.single().computation.total) // original preserved
        assertEquals(listOf("EXPENSE_CREATED", "PAYMENT_REPORTED", "PAYMENT_CONFIRMED", "EXPENSE_EDITED"), l.audit.map { it.type })
        assertTrue(l.audit.last().before!!.contains("v1") && l.audit.last().after!!.contains("v2"))
    }

    @Test fun `L reversal corrects a confirmed payment without deleting it`() {
        var l = owes1000().reportPayment("bilal", "r1", "bilal", "ahmed", R(1000), "k").confirmPayment("ahmed", "r1", R(1000))
        assertFailsWith<HisabException> { l.reversePayment("ahmed", "r1", "") }
        l = l.reversePayment("ahmed", "r1", "was a different transfer")
        assertEquals(R(1000), l.outstanding("bilal", "ahmed"))
        assertEquals(RepaymentStatus.REVERSED, l.repayments.single().status)
        assertEquals(R(1000), l.repayments.single().confirmedAmount) // original figure kept for audit
        assertEquals("PAYMENT_REVERSED", l.audit.last().type)
    }

    @Test fun `voiding an expense with confirmed payments requires acknowledgement`() {
        val l = owes1000().reportPayment("bilal", "r", "bilal", "ahmed", R(100), "k").confirmPayment("ahmed", "r", R(100))
        assertFailsWith<HisabException> { l.voidExpense("ahmed", "g", "mistake") }
        val v = l.voidExpense("ahmed", "g", "mistake", true)
        assertTrue(v.activeDebts.isEmpty()); assertEquals(1, v.expenseHistory.size)
    }

    @Test fun `cash recorded by recipient is confirmed immediately and idempotent`() {
        val l = owes1000().recordCash("ahmed", "c1", "bilal", "ahmed", R(300), "ck")
        assertEquals(R(700), l.outstanding("bilal", "ahmed"))
        assertEquals(l, l.recordCash("ahmed", "c2", "bilal", "ahmed", R(300), "ck"))
        assertFailsWith<HisabException> { l.recordCash("bilal", "c3", "bilal", "ahmed", R(1), "other") }
    }
}

class ReminderTest {
    private val policy = ReminderPolicy(ReminderInterval.H6, maxReminders = 5, graceAfterReportHours = 12)
    private val t0 = 1_000_000_000L

    @Test fun `first reminder is due one interval after creation`() {
        val st = ReminderState.initial("s1", t0, policy)
        assertEquals("not due yet", (ReminderEngine.decide(t0 + 5 * HOUR, st, R(100), policy) as ReminderDecision.Skip).reason)
        assertTrue(ReminderEngine.decide(t0 + 6 * HOUR, st, R(100), policy) is ReminderDecision.Send)
    }

    @Test fun `F settled debt gets nothing and partial debt is reminded for the remainder only`() {
        val st = ReminderState.initial("s1", t0, policy)
        val now = t0 + 7 * HOUR
        assertEquals("settled", (ReminderEngine.decide(now, st, 0, policy) as ReminderDecision.Skip).reason)
        val send = ReminderEngine.decide(now, st, R(400), policy) as ReminderDecision.Send
        assertEquals(R(400), send.remaining)
    }

    @Test fun `G opted out guest is not reminded but share stays in the accounting`() {
        val spec = ExpenseSpec.quick(
            "e", "Lunch", "ahmed", R(1000), setOf("ahmed", "guest1"), mapOf("ahmed" to R(1000)),
            remindersDisabledFor = setOf("guest1"),
        )
        val l = Ledger().addExpense("ahmed", spec)
        assertEquals(R(500), l.outstanding("guest1", "ahmed"))
        assertEquals(R(500), ExpenseEngine.compute(spec).shares["guest1"])
        val st = ReminderState.initial("e:guest1", t0, policy, enabled = "guest1" !in spec.remindersDisabledFor)
        val d = ReminderEngine.decide(t0 + 100 * HOUR, st, l.outstanding("guest1", "ahmed"), policy)
        assertEquals("reminders disabled for this person", (d as ReminderDecision.Skip).reason)
        // re-enabling resumes reminders
        assertTrue(ReminderEngine.decide(t0 + 100 * HOUR, st.copy(remindersEnabled = true), R(500), policy) is ReminderDecision.Send)
    }

    @Test fun `H running the scheduler twice never duplicates a reminder`() {
        val states = mapOf("s1" to ReminderState.initial("s1", t0, policy), "s2" to ReminderState.initial("s2", t0, policy))
        val run = ReminderRun()
        val (first, afterFirst) = run.run(t0 + 6 * HOUR, states, { R(100) }, policy)
        assertEquals(2, first.size)
        // the same stale state replayed (e.g. job retried before state was persisted): claims block duplicates
        val (replayed, _) = run.run(t0 + 6 * HOUR, states, { R(100) }, policy)
        assertEquals(0, replayed.size)
        // with the persisted state it is simply not due again yet
        val (second, _) = run.run(t0 + 7 * HOUR, afterFirst, { R(100) }, policy)
        assertEquals(0, second.size)
    }

    @Test fun `stops at the maximum count and pauses while a report awaits confirmation`() {
        var st = ReminderState.initial("s", t0, policy)
        var now = t0
        var sent = 0
        repeat(20) {
            now += 6 * HOUR
            if (ReminderEngine.decide(now, st, R(10), policy) is ReminderDecision.Send) { sent++; st = ReminderEngine.afterSend(now, st, policy) }
        }
        assertEquals(5, sent)
        val fresh = ReminderState.initial("s", t0, policy)
        val paused = ReminderEngine.pauseForReport(t0 + 6 * HOUR, fresh, policy)
        assertEquals("paused: payment awaiting confirmation",
            (ReminderEngine.decide(t0 + 10 * HOUR, paused, R(10), policy) as ReminderDecision.Skip).reason)
        assertTrue(ReminderEngine.decide(t0 + 19 * HOUR, paused, R(10), policy) is ReminderDecision.Send)
    }

    @Test fun `missing channel and voided expense suppress reminders`() {
        val st = ReminderState.initial("s", t0, policy)
        assertFalse(ReminderEngine.decide(t0 + 7 * HOUR, st, R(5), policy, channelConfigured = false) is ReminderDecision.Send)
        assertFalse(ReminderEngine.decide(t0 + 7 * HOUR, st, R(5), policy, expenseVoided = true) is ReminderDecision.Send)
    }
}
