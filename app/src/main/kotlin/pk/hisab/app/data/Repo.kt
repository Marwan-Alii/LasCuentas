package pk.hisab.app.data

import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.*
import pk.hisab.app.BuildConfig
import pk.hisab.core.*
import java.util.UUID

/**
 * All server access. Every write is an RPC to an audited server function; the server re-validates
 * everything (see supabase/migrations). Errors from the server are surfaced verbatim to the user.
 */
class Repo {
    val configured = BuildConfig.SUPABASE_URL.isNotBlank() && BuildConfig.SUPABASE_ANON_KEY.isNotBlank()
    private val client by lazy {
        createSupabaseClient(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY) { install(Auth); install(Postgrest) }
    }
    val auth get() = client.auth
    private val db get() = client.postgrest

    suspend fun signUp(email: String, password: String, name: String) {
        auth.signUpWith(Email) { this.email = email; this.password = password; data = buildJsonObject { put("display_name", name) } }
    }
    suspend fun signIn(email: String, password: String) { auth.signInWith(Email) { this.email = email; this.password = password } }
    suspend fun signOut() = auth.signOut()
    suspend fun resetPassword(email: String) = auth.resetPasswordForEmail(email)

    private suspend inline fun <reified T> rpc(fn: String, args: JsonObject = JsonObject(emptyMap())): T = db.rpc(fn, args).decodeAs<T>()
    private suspend fun call(fn: String, args: JsonObject) { db.rpc(fn, args) }

    suspend fun myParty(): String = rpc("my_party")
    suspend fun dashboard(): Dashboard = rpc("my_dashboard")
    suspend fun parties(): List<PartyRow> = db.from("parties").select().decodeList()
    suspend fun expenses(): List<ExpenseRow> = db.from("expenses").select { order("created_at", Order.DESCENDING) }.decodeList()
    suspend fun debts(): List<DebtBalance> = db.from("debt_balances").select().decodeList()
    suspend fun pairs(): List<PairBalance> = db.from("pair_balances").select().decodeList()
    suspend fun repayments(): List<RepaymentRow> = db.from("repayments").select { order("created_at", Order.DESCENDING) }.decodeList()
    suspend fun suggestions(): List<Suggestion> = rpc("suggest_settlements")
    suspend fun notifications(): List<NotificationRow> = db.from("notifications").select { order("created_at", Order.DESCENDING); limit(100) }.decodeList()
    suspend fun activity(): List<ActivityRow> = db.from("activity_events").select { order("created_at", Order.DESCENDING); limit(100) }.decodeList()
    suspend fun groups(): List<GroupRow> = db.from("groups").select().decodeList()
    suspend fun paymentMethods(): List<PaymentMethod> = db.from("payment_methods").select().decodeList()

    suspend fun methodsFor(creditorParty: String): List<PaymentMethod> = rpc("payment_methods_for_creditor", buildJsonObject { put("p_creditor_party", creditorParty) })
    suspend fun addPaymentMethod(m: PaymentMethod) { db.from("payment_methods").insert(m.copy(id = null, isDefault = false)) }
    suspend fun deletePaymentMethod(id: String) { db.from("payment_methods").delete { filter { eq("id", id) } } }
    suspend fun setDefaultMethod(id: String) = call("set_default_payment_method", buildJsonObject { put("p_id", id) })

    suspend fun createGroup(name: String, description: String?) = call("create_group", buildJsonObject { put("p_name", name); put("p_description", description) })
    suspend fun joinGroup(code: String) = call("join_group", buildJsonObject { put("p_code", code) })
    suspend fun createInvite(groupId: String): String = rpc("create_group_invite", buildJsonObject { put("p_group", groupId) })
    suspend fun createGuest(name: String, email: String?, whatsapp: String?) =
        call("create_guest", buildJsonObject { put("p_name", name); put("p_email", email); put("p_whatsapp", whatsapp) })
    suspend fun claimGuest(partyId: String) = call("claim_guest_profile", buildJsonObject { put("p_guest", partyId) })

    suspend fun reportPayment(from: String, to: String, amount: Long, reference: String?, note: String?, key: String = UUID.randomUUID().toString()) =
        call("report_payment", buildJsonObject {
            put("p_key", key); put("p_from", from); put("p_to", to); put("p_amount", amount); put("p_reference", reference); put("p_note", note)
        })
    suspend fun confirmPayment(id: String, amount: Long) = call("confirm_payment", buildJsonObject { put("p_repayment", id); put("p_amount", amount) })
    suspend fun disputePayment(id: String, reason: String) = call("dispute_payment", buildJsonObject { put("p_repayment", id); put("p_reason", reason) })
    suspend fun rejectPayment(id: String, reason: String) = call("reject_payment", buildJsonObject { put("p_repayment", id); put("p_reason", reason) })
    suspend fun recordCash(from: String, to: String, amount: Long) =
        call("record_cash", buildJsonObject { put("p_key", UUID.randomUUID().toString()); put("p_from", from); put("p_to", to); put("p_amount", amount) })
    suspend fun markAllRead() = call("mark_all_notifications_read", JsonObject(emptyMap()))
    suspend fun markRead(id: String) = call("mark_notification_read", buildJsonObject { put("p_id", id) })
    suspend fun whatsappTarget(debtId: String): WhatsAppTarget? =
        rpc<List<WhatsAppTarget>>("whatsapp_reminder_target", buildJsonObject { put("p_debt", debtId) }).firstOrNull()

    /**
     * Sends an expense built with the shared accounting engine. [opId] must stay the same across retries
     * of one user action so the server can deduplicate (no double expense after a dropped connection).
     */
    suspend fun createExpense(
        spec: ExpenseSpec, groupId: String?, notes: String?, intervalHours: Int, maxReminders: Int, opId: String,
    ): String {
        val c = ExpenseEngine.compute(spec)
        val payload = buildJsonObject {
            put("client_op_id", opId); put("title", spec.title); put("notes", notes); put("group_id", groupId)
            put("total_minor", c.total); put("reminder_interval_hours", intervalHours); put("reminder_max", maxReminders)
            putJsonArray("items") {
                spec.items.forEach { i ->
                    addJsonObject {
                        put("name", i.name); put("quantity", i.quantity); put("unit_minor", i.unitPrice)
                        put("method", methodName(i.method))
                        putJsonArray("allocations") { c.itemAllocations.getValue(i.id).shares.forEach { (p, a) -> addJsonObject { put("party_id", p); put("amount_minor", a) } } }
                    }
                }
                spec.charges.forEach { ch ->
                    addJsonObject {
                        put("name", ch.name); put("kind", "charge"); put("quantity", 1); put("unit_minor", ch.amount); put("method", "equal")
                        putJsonArray("allocations") { c.chargeAllocations.getValue(ch.id).shares.forEach { (p, a) -> addJsonObject { put("party_id", p); put("amount_minor", a) } } }
                    }
                }
            }
            putJsonArray("contributions") { spec.contributions.forEach { (p, a) -> addJsonObject { put("party_id", p); put("amount_minor", a) } } }
            putJsonObject("remind") { spec.participants.forEach { put(it, it !in spec.remindersDisabledFor) } }
        }
        return rpc("create_expense", buildJsonObject { put("p", payload) })
    }

    private fun methodName(m: AllocationMethod) = when (m) {
        is AllocationMethod.Equal -> "equal"; is AllocationMethod.Custom -> "custom"
        is AllocationMethod.Quantity -> "quantity"; is AllocationMethod.Proportional -> "proportional"
    }
}
