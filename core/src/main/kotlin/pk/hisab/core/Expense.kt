package pk.hisab.core

data class ExpenseItem(
    val id: String,
    val name: String,
    val quantity: Int,
    val unitPrice: Paisa,
    val method: AllocationMethod,
    val category: String? = null,
) {
    val lineTotal: Paisa get() = Math.multiplyExact(quantity.toLong(), unitPrice)
}

/** How a shared extra charge (delivery, tip, tax) is divided. */
sealed interface ChargeMethod {
    data class Equal(val participants: Set<PartyId>) : ChargeMethod

    /** In proportion to what each person's items cost. null = all expense participants. */
    data class ProportionalToItems(val participants: Set<PartyId>? = null) : ChargeMethod

    data class Custom(val amounts: Map<PartyId, Paisa>) : ChargeMethod
}

data class ExtraCharge(val id: String, val name: String, val amount: Paisa, val method: ChargeMethod)

/**
 * Everything the accounting engine needs to know about one expense.
 * [contributions] is what each person actually paid toward the original bill (not repayments).
 * [remindersDisabledFor] keeps the share in the accounting but suppresses automated reminders.
 */
data class ExpenseSpec(
    val id: String,
    val title: String,
    val createdBy: PartyId,
    val participants: Set<PartyId>,
    val items: List<ExpenseItem>,
    val charges: List<ExtraCharge> = emptyList(),
    val contributions: Map<PartyId, Paisa>,
    val recordedTotal: Paisa? = null,
    val remindersDisabledFor: Set<PartyId> = emptySet(),
) {
    companion object {
        /** "Quick total" mode: a single line allocated with [method] (default: equal among participants). */
        fun quick(
            id: String, title: String, createdBy: PartyId, total: Paisa,
            participants: Set<PartyId>, contributions: Map<PartyId, Paisa>,
            method: AllocationMethod = AllocationMethod.Equal(participants),
            remindersDisabledFor: Set<PartyId> = emptySet(),
        ) = ExpenseSpec(
            id, title, createdBy, participants,
            items = listOf(ExpenseItem("$id#total", title, 1, total, method)),
            contributions = contributions, recordedTotal = total,
            remindersDisabledFor = remindersDisabledFor,
        )
    }
}

data class ExpenseComputation(
    val total: Paisa,
    /** What each participant owes for this expense (their fair share). Includes zero shares. */
    val shares: Map<PartyId, Paisa>,
    val itemAllocations: Map<String, AllocationResult>,
    val chargeAllocations: Map<String, AllocationResult>,
    val contributions: Map<PartyId, Paisa>,
    /** Part of the bill nobody has been recorded as paying. Never hidden. */
    val unpaid: Paisa,
    /** contribution - share. Positive = should receive, negative = owes. */
    val netPositions: Map<PartyId, Paisa>,
)

object ExpenseEngine {

    fun compute(spec: ExpenseSpec): ExpenseComputation {
        require(spec.title.isNotBlank()) { "Expense title is required" }
        require(spec.participants.isNotEmpty()) { "At least one participant is required" }
        require(spec.items.isNotEmpty()) { "At least one item or a total is required" }

        val itemAllocs = LinkedHashMap<String, AllocationResult>()
        var itemsTotal = 0L
        for (item in spec.items) {
            require(item.quantity >= 1) { "Quantity of '${item.name}' must be at least 1" }
            require(item.unitPrice >= 0) { "Price of '${item.name}' cannot be negative" }
            checkParties(item.name, partiesOf(item.method), spec.participants)
            val m = item.method
            if (m is AllocationMethod.Quantity) {
                val units = m.quantities.values.sum()
                require(units == item.quantity) {
                    "Units assigned for '${item.name}' ($units) must equal its quantity (${item.quantity})"
                }
            }
            val line = try { item.lineTotal } catch (e: ArithmeticException) {
                throw HisabException("Amount for '${item.name}' is too large")
            }
            itemAllocs[item.id] = Allocator.allocate(line, m)
            itemsTotal = Math.addExact(itemsTotal, line)
        }

        val itemSubtotal = HashMap<PartyId, Paisa>()
        itemAllocs.values.forEach { r -> r.shares.forEach { (p, v) -> itemSubtotal.merge(p, v, Long::plus) } }

        val chargeAllocs = LinkedHashMap<String, AllocationResult>()
        var chargesTotal = 0L
        for (c in spec.charges) {
            require(c.amount >= 0) { "Charge '${c.name}' cannot be negative" }
            val method: AllocationMethod = when (val cm = c.method) {
                is ChargeMethod.Equal -> AllocationMethod.Equal(cm.participants)
                is ChargeMethod.Custom -> AllocationMethod.Custom(cm.amounts)
                is ChargeMethod.ProportionalToItems -> {
                    val who = cm.participants ?: spec.participants
                    AllocationMethod.Proportional(who.associateWith { itemSubtotal[it] ?: 0L })
                }
            }
            checkParties(c.name, partiesOf(method), spec.participants)
            chargeAllocs[c.id] = Allocator.allocate(c.amount, method)
            chargesTotal = Math.addExact(chargesTotal, c.amount)
        }

        val total = Math.addExact(itemsTotal, chargesTotal)
        spec.recordedTotal?.let {
            require(it == total) { "Recorded total (${formatPkr(it)}) does not match items and charges (${formatPkr(total)})" }
        }

        val shares = spec.participants.associateWith { 0L }.toMutableMap()
        (itemAllocs.values + chargeAllocs.values).forEach { r ->
            r.shares.forEach { (p, v) -> shares.merge(p, v, Long::plus) }
        }
        require(shares.values.sum() == total) { "Internal error: shares do not reconcile to the total" }

        require(spec.contributions.values.all { it >= 0 }) { "Contributions cannot be negative" }
        val contributed = spec.contributions.values.sum()
        require(contributed <= total) {
            "Contributions (${formatPkr(contributed)}) exceed the expense total (${formatPkr(total)})"
        }

        val everyone = (spec.participants + spec.contributions.keys).toSortedSet()
        val net = everyone.associateWith { (spec.contributions[it] ?: 0L) - (shares[it] ?: 0L) }
        return ExpenseComputation(
            total = total,
            shares = shares.toSortedMap(),
            itemAllocations = itemAllocs,
            chargeAllocations = chargeAllocs,
            contributions = spec.contributions.toSortedMap(),
            unpaid = total - contributed,
            netPositions = net,
        )
    }

    private fun partiesOf(m: AllocationMethod): Set<PartyId> = when (m) {
        is AllocationMethod.Equal -> m.participants
        is AllocationMethod.Custom -> m.amounts.keys
        is AllocationMethod.Quantity -> m.quantities.keys
        is AllocationMethod.Proportional -> m.weights.keys
    }

    private fun checkParties(what: String, used: Set<PartyId>, allowed: Set<PartyId>) {
        val stray = used - allowed
        require(stray.isEmpty()) { "'$what' is allocated to people who are not participants: ${stray.sorted()}" }
    }
}
