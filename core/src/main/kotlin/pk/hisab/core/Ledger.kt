package pk.hisab.core

/** An obligation created by one expense: [debtor] owes [creditor] [amount]. Derived, never edited. */
data class Debt(
    val id: String,
    val expenseId: String,
    val debtor: PartyId,
    val creditor: PartyId,
    val amount: Paisa,
    /** Creation order of the owning expense; repayments are applied oldest-first. */
    val seq: Long,
)

object DebtDeriver {
    /**
     * Turns net positions into direct debts. Debtors and creditors are matched largest-first
     * (ties by id), which is exact, deterministic and uses the fewest debts.
     * If part of the bill is still unpaid by anyone ([unpaid] > 0), no debts are produced: the
     * expense is visibly incomplete instead of guessing who is owed.
     */
    fun derive(expenseId: String, net: Map<PartyId, Paisa>, unpaid: Paisa, seq: Long): List<Debt> {
        if (unpaid != 0L) return emptyList()
        val debtors = net.filter { it.value < 0 }
            .map { it.key to -it.value }
            .sortedWith(compareByDescending<Pair<PartyId, Paisa>> { it.second }.thenBy { it.first })
            .toMutableList()
        val creditors = net.filter { it.value > 0 }
            .map { it.key to it.value }
            .sortedWith(compareByDescending<Pair<PartyId, Paisa>> { it.second }.thenBy { it.first })
            .toMutableList()
        val out = ArrayList<Debt>()
        var di = 0
        var ci = 0
        while (di < debtors.size && ci < creditors.size) {
            val (d, dAmt) = debtors[di]
            val (c, cAmt) = creditors[ci]
            val x = minOf(dAmt, cAmt)
            out += Debt("$expenseId:$d>$c", expenseId, d, c, x, seq)
            debtors[di] = d to dAmt - x
            creditors[ci] = c to cAmt - x
            if (debtors[di].second == 0L) di++
            if (creditors[ci].second == 0L) ci++
        }
        return out
    }
}

enum class RepaymentStatus { REPORTED, DISPUTED, CONFIRMED, REJECTED, REVERSED }

/**
 * A repayment between two people. Reporting it never reduces a debt; only recipient
 * confirmation (or cash recorded by the recipient) does, and only for the confirmed amount.
 */
data class Repayment(
    val id: String,
    val from: PartyId,
    val to: PartyId,
    val reportedAmount: Paisa,
    val confirmedAmount: Paisa = 0,
    val status: RepaymentStatus,
    val idempotencyKey: String,
    val reference: String? = null,
    val note: String? = null,
    val reason: String? = null,
    val confirmSeq: Long? = null,
    val cashRecordedByRecipient: Boolean = false,
)

data class AuditEvent(
    val seq: Long,
    val type: String,
    val actor: PartyId,
    val subjectId: String,
    val before: String?,
    val after: String?,
    val reason: String?,
)

data class ExpenseRecord(
    val spec: ExpenseSpec,
    val computation: ExpenseComputation,
    val version: Int,
    val voided: Boolean,
    val createdSeq: Long,
)

enum class DebtStatus { OUTSTANDING, AWAITING_CONFIRMATION, PARTIALLY_PAID, DISPUTED, SETTLED }

data class DebtView(
    val debt: Debt,
    val confirmedPaid: Paisa,
    /** Confirmed outstanding balance. Unconfirmed reports do NOT reduce it. */
    val outstanding: Paisa,
    /** Reported but not yet confirmed (attributed oldest-debt-first). */
    val awaitingConfirmation: Paisa,
    val status: DebtStatus,
)

data class PairSummary(
    val debtor: PartyId,
    val creditor: PartyId,
    val original: Paisa,
    val confirmedReceived: Paisa,
    val awaitingConfirmation: Paisa,
    val outstanding: Paisa,
    /** Confirmed money beyond current debts (only possible after an acknowledged correction). */
    val unappliedCredit: Paisa,
)

data class PairEffect(
    val debtor: PartyId,
    val creditor: PartyId,
    val originalBefore: Paisa,
    val originalAfter: Paisa,
    val confirmedReceived: Paisa,
    val outstandingBefore: Paisa,
    val outstandingAfter: Paisa,
    val overpaid: Paisa,
)

data class SuggestedTransfer(
    val from: PartyId,
    val to: PartyId,
    val amount: Paisa,
    val grossOwed: Paisa,
    val grossOwedBack: Paisa,
    /** Exactly which debts (oldest first) a recorded payment of [amount] would be applied to. */
    val allocation: List<Pair<String, Paisa>>,
)

data class Position(val owedToMe: Paisa, val iOwe: Paisa) { val net: Paisa get() = owedToMe - iOwe }

/**
 * Immutable ledger. Every balance is derived from expenses + repayment events; there are no
 * editable balance fields. All mutating operations return a new Ledger and append audit events.
 */
data class Ledger(
    val expenses: Map<String, ExpenseRecord> = emptyMap(),
    val expenseHistory: List<ExpenseRecord> = emptyList(),
    val repayments: List<Repayment> = emptyList(),
    val audit: List<AuditEvent> = emptyList(),
    private val nextSeq: Long = 1,
) {
    // ---------------------------------------------------------------- derived state

    val activeDebts: List<Debt>
        get() = expenses.values.filter { !it.voided }
            .flatMap { DebtDeriver.derive(it.spec.id, it.computation.netPositions, it.computation.unpaid, it.createdSeq) }
            .sortedWith(compareBy<Debt> { it.seq }.thenBy { it.id })

    private data class Replay(
        val paidByDebt: Map<String, Paisa>,
        val unappliedByPair: Map<Pair<PartyId, PartyId>, Paisa>,
    )

    private fun replay(): Replay {
        val debtsByPair = activeDebts.groupBy { it.debtor to it.creditor }
        val paid = HashMap<String, Paisa>()
        val unapplied = HashMap<Pair<PartyId, PartyId>, Paisa>()
        repayments.filter { it.status == RepaymentStatus.CONFIRMED }
            .sortedBy { it.confirmSeq }
            .forEach { r ->
                var left = r.confirmedAmount
                for (d in debtsByPair[r.from to r.to].orEmpty()) {
                    if (left == 0L) break
                    val room = d.amount - (paid[d.id] ?: 0L)
                    val x = minOf(room, left)
                    if (x > 0) { paid.merge(d.id, x, Long::plus); left -= x }
                }
                if (left > 0) unapplied.merge(r.from to r.to, left, Long::plus)
            }
        return Replay(paid, unapplied)
    }

    fun debtViews(): List<DebtView> {
        val rp = replay()
        val debts = activeDebts
        val views = ArrayList<DebtView>()
        for ((pair, list) in debts.groupBy { it.debtor to it.creditor }) {
            val pending = repayments.filter {
                it.from == pair.first && it.to == pair.second &&
                    (it.status == RepaymentStatus.REPORTED || it.status == RepaymentStatus.DISPUTED)
            }
            var pendingLeft = pending.sumOf { it.reportedAmount }
            val disputed = pending.any { it.status == RepaymentStatus.DISPUTED }
            for (d in list) {
                val paid = rp.paidByDebt[d.id] ?: 0L
                val outstanding = d.amount - paid
                val waiting = minOf(outstanding, pendingLeft)
                pendingLeft -= waiting
                val status = when {
                    outstanding == 0L -> DebtStatus.SETTLED
                    waiting > 0 && disputed -> DebtStatus.DISPUTED
                    waiting > 0 -> DebtStatus.AWAITING_CONFIRMATION
                    paid > 0 -> DebtStatus.PARTIALLY_PAID
                    else -> DebtStatus.OUTSTANDING
                }
                views += DebtView(d, paid, outstanding, waiting, status)
            }
        }
        return views.sortedWith(compareBy<DebtView> { it.debt.seq }.thenBy { it.debt.id })
    }

    fun pairSummary(debtor: PartyId, creditor: PartyId): PairSummary {
        val v = debtViews().filter { it.debt.debtor == debtor && it.debt.creditor == creditor }
        val unapplied = replay().unappliedByPair[debtor to creditor] ?: 0L
        return PairSummary(
            debtor, creditor,
            original = v.sumOf { it.debt.amount },
            confirmedReceived = v.sumOf { it.confirmedPaid },
            awaitingConfirmation = v.sumOf { it.awaitingConfirmation },
            outstanding = v.sumOf { it.outstanding },
            unappliedCredit = unapplied,
        )
    }

    /** Confirmed outstanding for a debtor→creditor pair (0 if none). */
    fun outstanding(debtor: PartyId, creditor: PartyId): Paisa = pairSummary(debtor, creditor).outstanding

    fun position(party: PartyId): Position {
        val v = debtViews()
        return Position(
            owedToMe = v.filter { it.debt.creditor == party }.sumOf { it.outstanding },
            iOwe = v.filter { it.debt.debtor == party }.sumOf { it.outstanding },
        )
    }

    /**
     * Pairwise net suggestions across expenses. Both underlying debts stay in the ledger; a
     * recorded transfer is applied to the payer's debts oldest-first and the breakdown is shown.
     */
    fun suggestSettlements(): List<SuggestedTransfer> {
        val views = debtViews().filter { it.outstanding > 0 }
        val gross = HashMap<Pair<PartyId, PartyId>, Paisa>()
        views.forEach { gross.merge(it.debt.debtor to it.debt.creditor, it.outstanding, Long::plus) }
        val pairs = gross.keys.map { (a, b) -> if (a < b) a to b else b to a }.toSortedSet(compareBy({ it.first }, { it.second }))
        val out = ArrayList<SuggestedTransfer>()
        for ((a, b) in pairs) {
            val ab = gross[a to b] ?: 0L
            val ba = gross[b to a] ?: 0L
            val (from, to, owed, back) = when {
                ab > ba -> Quad(a, b, ab, ba)
                ba > ab -> Quad(b, a, ba, ab)
                else -> continue
            }
            var left = owed - back
            val alloc = ArrayList<Pair<String, Paisa>>()
            for (v in views.filter { it.debt.debtor == from && it.debt.creditor == to }) {
                if (left == 0L) break
                val x = minOf(left, v.outstanding)
                alloc += v.debt.id to x
                left -= x
            }
            out += SuggestedTransfer(from, to, owed - back, owed, back, alloc)
        }
        return out
    }

    private data class Quad(val a: PartyId, val b: PartyId, val c: Paisa, val d: Paisa)

    // ---------------------------------------------------------------- expenses

    fun addExpense(actor: PartyId, spec: ExpenseSpec): Ledger {
        require(actor == spec.createdBy) { "Only the creator can record this expense" }
        require(spec.id !in expenses) { "Expense ${spec.id} already exists" }
        val comp = ExpenseEngine.compute(spec)
        val rec = ExpenseRecord(spec, comp, 1, false, nextSeq)
        return copy(expenses = expenses + (spec.id to rec)).log(
            "EXPENSE_CREATED", actor, spec.id, null, describe(rec), null,
        )
    }

    /** Shows the financial effect of a correction before it is applied. */
    fun previewRevision(newSpec: ExpenseSpec): List<PairEffect> {
        val old = expenses[newSpec.id] ?: throw HisabException("Unknown expense ${newSpec.id}")
        val comp = ExpenseEngine.compute(newSpec)
        val candidate = copy(expenses = expenses + (newSpec.id to old.copy(spec = newSpec, computation = comp)))
        return effects(candidate)
    }

    fun reviseExpense(
        actor: PartyId, newSpec: ExpenseSpec, expectedVersion: Int, reason: String,
        acknowledgeOverpayment: Boolean = false,
    ): Ledger {
        val old = expenses[newSpec.id] ?: throw HisabException("Unknown expense ${newSpec.id}")
        require(!old.voided) { "A voided expense cannot be edited" }
        require(actor == old.spec.createdBy) { "Only the creator can edit this expense" }
        require(newSpec.createdBy == old.spec.createdBy) { "The creator of an expense cannot be changed" }
        require(old.version == expectedVersion) {
            "This expense was changed by someone else (now version ${old.version}). Reload and retry."
        }
        require(reason.isNotBlank()) { "A reason is required to edit an expense" }
        val comp = ExpenseEngine.compute(newSpec)
        val rec = old.copy(spec = newSpec, computation = comp, version = old.version + 1)
        val candidate = copy(expenses = expenses + (newSpec.id to rec))
        val over = effects(candidate).filter { it.overpaid > 0 }
        require(over.isEmpty() || acknowledgeOverpayment) {
            "This change leaves confirmed repayments larger than what is now owed " +
                "(${over.joinToString { "${it.debtor}→${it.creditor}: ${formatPkr(it.overpaid)}" }}). Acknowledge to continue."
        }
        return candidate.copy(expenseHistory = expenseHistory + old)
            .log("EXPENSE_EDITED", actor, newSpec.id, describe(old), describe(rec), reason)
    }

    fun voidExpense(actor: PartyId, expenseId: String, reason: String, acknowledgeOverpayment: Boolean = false): Ledger {
        val old = expenses[expenseId] ?: throw HisabException("Unknown expense $expenseId")
        require(!old.voided) { "Expense is already voided" }
        require(actor == old.spec.createdBy) { "Only the creator can void this expense" }
        require(reason.isNotBlank()) { "A reason is required to void an expense" }
        val candidate = copy(expenses = expenses + (expenseId to old.copy(voided = true, version = old.version + 1)))
        val over = effects(candidate).filter { it.overpaid > 0 }
        require(over.isEmpty() || acknowledgeOverpayment) {
            "Voiding leaves confirmed repayments with nothing to apply to. Acknowledge to continue."
        }
        return candidate.copy(expenseHistory = expenseHistory + old)
            .log("EXPENSE_VOIDED", actor, expenseId, describe(old), "voided", reason)
    }

    private fun effects(candidate: Ledger): List<PairEffect> {
        val pairs = (activeDebts + candidate.activeDebts).map { it.debtor to it.creditor }.toSortedSet(compareBy({ it.first }, { it.second }))
        return pairs.map { (d, c) ->
            val b = pairSummary(d, c)
            val a = candidate.pairSummary(d, c)
            PairEffect(d, c, b.original, a.original, a.confirmedReceived, b.outstanding, a.outstanding, a.unappliedCredit)
        }.filter { it.originalBefore != it.originalAfter || it.overpaid > 0 }
    }

    // ---------------------------------------------------------------- repayments

    /** Debtor reports a payment made outside the app. Does NOT reduce any debt. Idempotent by [idempotencyKey]. */
    fun reportPayment(
        actor: PartyId, repaymentId: String, from: PartyId, to: PartyId, amount: Paisa,
        idempotencyKey: String, reference: String? = null, note: String? = null,
    ): Ledger {
        require(actor == from) { "Only the payer can report a payment" }
        repayments.firstOrNull { it.idempotencyKey == idempotencyKey }?.let { existing ->
            require(existing.from == from && existing.to == to && existing.reportedAmount == amount) {
                "Idempotency key already used for a different payment"
            }
            return this
        }
        require(repayments.none { it.id == repaymentId }) { "Repayment $repaymentId already exists" }
        require(amount > 0) { "Payment amount must be greater than zero" }
        val out = outstanding(from, to)
        require(out > 0) { "Nothing is owed from $from to $to" }
        require(amount <= out) { "Amount (${formatPkr(amount)}) is more than the outstanding ${formatPkr(out)}" }
        val r = Repayment(repaymentId, from, to, amount, 0, RepaymentStatus.REPORTED, idempotencyKey, reference, note)
        return copy(repayments = repayments + r)
            .log("PAYMENT_REPORTED", actor, repaymentId, null, "reported ${formatPkr(amount)}", null)
    }

    /** Recipient confirms what was actually received (may be less than reported). */
    fun confirmPayment(actor: PartyId, repaymentId: String, confirmedAmount: Paisa): Ledger {
        val r = find(repaymentId)
        require(actor == r.to) { "Only the recipient can confirm receipt" }
        if (r.status == RepaymentStatus.CONFIRMED) {
            require(r.confirmedAmount == confirmedAmount) { "Already confirmed with a different amount" }
            return this
        }
        require(r.status == RepaymentStatus.REPORTED || r.status == RepaymentStatus.DISPUTED) {
            "A ${r.status.name.lowercase()} payment cannot be confirmed"
        }
        require(confirmedAmount > 0) { "Confirmed amount must be greater than zero" }
        require(confirmedAmount <= r.reportedAmount) { "Confirmed amount cannot exceed the reported amount" }
        val out = outstanding(r.from, r.to)
        require(confirmedAmount <= out) { "Confirmed amount exceeds what is outstanding (${formatPkr(out)})" }
        val updated = r.copy(status = RepaymentStatus.CONFIRMED, confirmedAmount = confirmedAmount, confirmSeq = nextSeq)
        return replace(updated).log(
            "PAYMENT_CONFIRMED", actor, repaymentId,
            "reported ${formatPkr(r.reportedAmount)}", "confirmed ${formatPkr(confirmedAmount)}", null,
        )
    }

    fun disputePayment(actor: PartyId, repaymentId: String, reason: String): Ledger {
        val r = find(repaymentId)
        require(actor == r.to) { "Only the recipient can dispute a report" }
        require(r.status == RepaymentStatus.REPORTED) { "Only a reported payment can be disputed" }
        require(reason.isNotBlank()) { "A reason is required" }
        return replace(r.copy(status = RepaymentStatus.DISPUTED, reason = reason))
            .log("PAYMENT_DISPUTED", actor, repaymentId, "reported", "disputed", reason)
    }

    fun rejectPayment(actor: PartyId, repaymentId: String, reason: String): Ledger {
        val r = find(repaymentId)
        require(actor == r.to) { "Only the recipient can reject a report" }
        require(r.status == RepaymentStatus.REPORTED || r.status == RepaymentStatus.DISPUTED) {
            "Only an unconfirmed payment can be rejected"
        }
        require(reason.isNotBlank()) { "A reason is required" }
        return replace(r.copy(status = RepaymentStatus.REJECTED, reason = reason))
            .log("PAYMENT_REJECTED", actor, repaymentId, r.status.name.lowercase(), "rejected", reason)
    }

    /** Recipient records cash handed over directly; confirmed immediately. Idempotent by key. */
    fun recordCash(
        actor: PartyId, repaymentId: String, from: PartyId, to: PartyId, amount: Paisa, idempotencyKey: String,
    ): Ledger {
        require(actor == to) { "Only the recipient can record cash received" }
        repayments.firstOrNull { it.idempotencyKey == idempotencyKey }?.let { return this }
        require(repayments.none { it.id == repaymentId }) { "Repayment $repaymentId already exists" }
        require(amount > 0) { "Amount must be greater than zero" }
        val out = outstanding(from, to)
        require(amount <= out) { "Amount (${formatPkr(amount)}) is more than the outstanding ${formatPkr(out)}" }
        val r = Repayment(
            repaymentId, from, to, amount, amount, RepaymentStatus.CONFIRMED, idempotencyKey,
            confirmSeq = nextSeq, cashRecordedByRecipient = true,
        )
        return copy(repayments = repayments + r)
            .log("CASH_RECORDED", actor, repaymentId, null, "received ${formatPkr(amount)} cash", null)
    }

    /** Corrects a confirmed payment with a reversal. The original record and its audit trail remain. */
    fun reversePayment(actor: PartyId, repaymentId: String, reason: String): Ledger {
        val r = find(repaymentId)
        require(actor == r.to) { "Only the recipient can reverse a confirmed payment" }
        require(r.status == RepaymentStatus.CONFIRMED) { "Only a confirmed payment can be reversed" }
        require(reason.isNotBlank()) { "A reason is required to reverse a payment" }
        return replace(r.copy(status = RepaymentStatus.REVERSED, reason = reason))
            .log("PAYMENT_REVERSED", actor, repaymentId, "confirmed ${formatPkr(r.confirmedAmount)}", "reversed", reason)
    }

    // ---------------------------------------------------------------- helpers

    private fun find(id: String) = repayments.firstOrNull { it.id == id } ?: throw HisabException("Unknown repayment $id")

    private fun replace(r: Repayment) = copy(repayments = repayments.map { if (it.id == r.id) r else it })

    private fun log(type: String, actor: PartyId, subject: String, before: String?, after: String?, reason: String?) =
        copy(audit = audit + AuditEvent(nextSeq, type, actor, subject, before, after, reason), nextSeq = nextSeq + 1)

    private fun describe(rec: ExpenseRecord) =
        "v${rec.version} '${rec.spec.title}' total=${rec.computation.total} shares=${rec.computation.shares}"
}
