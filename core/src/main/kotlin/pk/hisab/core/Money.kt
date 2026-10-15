package pk.hisab.core

/** Stable identifier of a participant (registered user OR guest profile). */
typealias PartyId = String

/** All money is integer paisa (1 PKR = 100 paisa). Floating point is never used. */
typealias Paisa = Long

/** Raised for any violated financial invariant or invalid operation. */
class HisabException(message: String) : IllegalArgumentException(message)

fun rupees(whole: Long, paisa: Long = 0): Paisa = Math.addExact(Math.multiplyExact(whole, 100L), paisa)

/** "Rs. 1,200" or "Rs. 1,200.50"; negative amounts are prefixed with "-". */
fun formatPkr(amount: Paisa): String {
    val neg = amount < 0
    val abs = Math.abs(amount)
    val whole = (abs / 100).toString().reversed().chunked(3).joinToString(",").reversed()
    val frac = abs % 100
    val body = if (frac == 0L) whole else "$whole.${frac.toString().padStart(2, '0')}"
    return (if (neg) "-" else "") + "Rs. " + body
}

internal fun require(cond: Boolean, msg: () -> String) {
    if (!cond) throw HisabException(msg())
}
