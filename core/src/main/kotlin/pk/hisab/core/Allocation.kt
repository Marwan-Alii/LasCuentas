package pk.hisab.core

import java.math.BigInteger

/** How a single amount (an item or a shared charge) is divided between people. */
sealed interface AllocationMethod {
    /** Equal split among the given people. */
    data class Equal(val participants: Set<PartyId>) : AllocationMethod

    /** Explicit amount per person; must sum exactly to the amount being allocated. */
    data class Custom(val amounts: Map<PartyId, Paisa>) : AllocationMethod

    /** Split by units consumed per person. For items, units must sum to the item quantity. */
    data class Quantity(val quantities: Map<PartyId, Int>) : AllocationMethod

    /** Split in proportion to arbitrary non-negative weights. */
    data class Proportional(val weights: Map<PartyId, Long>) : AllocationMethod
}

/**
 * Result of allocating one amount.
 * [roundingAdjustments] lists the people who received one extra paisa because the amount was
 * not exactly divisible (largest remainder first, ties broken by ascending party id).
 */
data class AllocationResult(
    val shares: Map<PartyId, Paisa>,
    val roundingAdjustments: Map<PartyId, Paisa>,
) {
    val total: Paisa get() = shares.values.sum()
}

object Allocator {

    fun allocate(total: Paisa, method: AllocationMethod): AllocationResult {
        require(total >= 0) { "Amount cannot be negative" }
        return when (method) {
            is AllocationMethod.Equal -> {
                require(method.participants.isNotEmpty()) { "Equal split needs at least one participant" }
                byWeights(total, method.participants.associateWith { 1L })
            }
            is AllocationMethod.Custom -> {
                require(method.amounts.values.all { it >= 0 }) { "Custom amounts cannot be negative" }
                val sum = method.amounts.values.sum()
                require(sum == total) {
                    "Custom amounts (${formatPkr(sum)}) must equal ${formatPkr(total)}"
                }
                AllocationResult(method.amounts.toSortedMap(), emptyMap())
            }
            is AllocationMethod.Quantity -> {
                require(method.quantities.values.all { it >= 0 }) { "Quantities cannot be negative" }
                byWeights(total, method.quantities.mapValues { it.value.toLong() })
            }
            is AllocationMethod.Proportional -> {
                require(method.weights.values.all { it >= 0 }) { "Weights cannot be negative" }
                byWeights(total, method.weights)
            }
        }
    }

    /** Largest-remainder apportionment: exact, deterministic, order-independent. */
    private fun byWeights(total: Paisa, weights: Map<PartyId, Long>): AllocationResult {
        val sumW = weights.values.fold(BigInteger.ZERO) { a, w -> a + BigInteger.valueOf(w) }
        require(sumW.signum() > 0) { "Allocation weights must not all be zero" }
        val bigTotal = BigInteger.valueOf(total)
        data class Part(val id: PartyId, val floor: Long, val rem: BigInteger)
        val parts = weights.map { (id, w) ->
            val prod = bigTotal * BigInteger.valueOf(w)
            val (q, r) = prod.divideAndRemainder(sumW)
            Part(id, q.toLong(), r)
        }
        var leftover = total - parts.sumOf { it.floor }
        val order = parts.sortedWith(compareByDescending<Part> { it.rem }.thenBy { it.id })
        val extra = HashMap<PartyId, Paisa>()
        for (p in order) {
            if (leftover == 0L) break
            extra[p.id] = 1L
            leftover--
        }
        val shares = parts.associate { it.id to it.floor + (extra[it.id] ?: 0L) }.toSortedMap()
        return AllocationResult(shares, extra.toSortedMap())
    }
}
