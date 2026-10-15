package pk.hisab.core

enum class ReminderInterval(val hours: Int) { H3(3), H6(6), H12(12), H24(24) }

data class ReminderPolicy(
    val interval: ReminderInterval,
    val maxReminders: Int = 5,
    /** Pause after the debtor reports a payment, to give the recipient time to confirm. */
    val graceAfterReportHours: Int = 12,
)

/** Server-side state kept per outstanding share (see public.reminder_schedules in the SQL schema). */
data class ReminderState(
    val shareId: String,
    val nextDueAtMillis: Long,
    val sent: Int = 0,
    /** false when the payer disabled reminders for this person on this expense, or they opted out. */
    val remindersEnabled: Boolean = true,
    val pausedUntilMillis: Long? = null,
) {
    companion object {
        /** The countdown starts when the expense is created; first reminder is due one interval later. */
        fun initial(shareId: String, createdAtMillis: Long, policy: ReminderPolicy, enabled: Boolean = true) =
            ReminderState(shareId, createdAtMillis + policy.interval.hours * HOUR, 0, enabled)
    }
}

const val HOUR = 3_600_000L

sealed interface ReminderDecision {
    /** Send a reminder about [remaining] (confirmed outstanding only). */
    data class Send(val shareId: String, val sequence: Int, val remaining: Paisa) : ReminderDecision

    data class Skip(val reason: String) : ReminderDecision
}

object ReminderEngine {

    fun decide(
        nowMillis: Long, state: ReminderState, confirmedOutstanding: Paisa, policy: ReminderPolicy,
        channelConfigured: Boolean = true, expenseVoided: Boolean = false,
    ): ReminderDecision = when {
        expenseVoided -> ReminderDecision.Skip("expense voided")
        confirmedOutstanding <= 0 -> ReminderDecision.Skip("settled")
        !state.remindersEnabled -> ReminderDecision.Skip("reminders disabled for this person")
        state.sent >= policy.maxReminders -> ReminderDecision.Skip("maximum reminders reached")
        !channelConfigured -> ReminderDecision.Skip("channel not configured")
        state.pausedUntilMillis != null && nowMillis < state.pausedUntilMillis -> ReminderDecision.Skip("paused: payment awaiting confirmation")
        nowMillis < state.nextDueAtMillis -> ReminderDecision.Skip("not due yet")
        else -> ReminderDecision.Send(state.shareId, state.sent + 1, confirmedOutstanding)
    }

    fun afterSend(nowMillis: Long, state: ReminderState, policy: ReminderPolicy) =
        state.copy(sent = state.sent + 1, nextDueAtMillis = nowMillis + policy.interval.hours * HOUR)

    fun pauseForReport(nowMillis: Long, state: ReminderState, policy: ReminderPolicy) =
        state.copy(pausedUntilMillis = nowMillis + policy.graceAfterReportHours * HOUR)
}

/**
 * Model of the idempotent scheduler run. The (shareId, sequence) pair is claimed exactly once,
 * mirroring the UNIQUE constraint on reminder_attempts in the database, so running the job twice
 * cannot produce duplicate reminders.
 */
class ReminderRun(private val claimed: MutableSet<Pair<String, Int>> = HashSet()) {
    fun run(
        nowMillis: Long, states: Map<String, ReminderState>, outstanding: (String) -> Paisa, policy: ReminderPolicy,
    ): Pair<List<ReminderDecision.Send>, Map<String, ReminderState>> {
        val sends = ArrayList<ReminderDecision.Send>()
        val next = HashMap(states)
        for ((id, st) in states.toSortedMap()) {
            val d = ReminderEngine.decide(nowMillis, st, outstanding(id), policy)
            if (d is ReminderDecision.Send && claimed.add(d.shareId to d.sequence)) {
                sends += d
                next[id] = ReminderEngine.afterSend(nowMillis, st, policy)
            }
        }
        return sends to next
    }
}
