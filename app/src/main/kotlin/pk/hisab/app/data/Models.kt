package pk.hisab.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable data class Dashboard(
    @SerialName("owed_to_me_minor") val owedToMe: Long = 0, @SerialName("i_owe_minor") val iOwe: Long = 0,
    @SerialName("awaiting_my_confirmation") val awaitingMyConfirmation: Int = 0,
    @SerialName("my_reports_awaiting") val myReportsAwaiting: Int = 0,
    @SerialName("unread_notifications") val unread: Int = 0)

@Serializable data class PartyRow(val id: String, val kind: String, @SerialName("display_name") val name: String)

@Serializable data class ExpenseRow(val id: String, val title: String, @SerialName("total_minor") val total: Long,
    @SerialName("unpaid_minor") val unpaid: Long, @SerialName("expense_date") val date: String, val status: String,
    val version: Int, @SerialName("group_id") val groupId: String? = null, @SerialName("created_by") val createdBy: String)

@Serializable data class DebtBalance(@SerialName("debt_id") val debtId: String, @SerialName("expense_id") val expenseId: String,
    @SerialName("debtor_party") val debtor: String, @SerialName("creditor_party") val creditor: String,
    @SerialName("expense_title") val title: String, @SerialName("original_minor") val original: Long,
    @SerialName("confirmed_paid_minor") val confirmedPaid: Long, @SerialName("outstanding_minor") val outstanding: Long)

@Serializable data class PairBalance(@SerialName("debtor_party") val debtor: String, @SerialName("creditor_party") val creditor: String,
    @SerialName("original_minor") val original: Long, @SerialName("confirmed_received_minor") val confirmedReceived: Long,
    @SerialName("outstanding_minor") val outstanding: Long, @SerialName("awaiting_confirmation_minor") val awaiting: Long,
    @SerialName("has_dispute") val hasDispute: Boolean = false)

@Serializable data class RepaymentRow(val id: String, @SerialName("from_party") val from: String, @SerialName("to_party") val to: String,
    @SerialName("reported_minor") val reported: Long, @SerialName("confirmed_minor") val confirmed: Long, val status: String,
    val reference: String? = null, val note: String? = null, @SerialName("created_at") val createdAt: String)

@Serializable data class Suggestion(@SerialName("from_party") val from: String, @SerialName("to_party") val to: String,
    @SerialName("amount_minor") val amount: Long, @SerialName("gross_owed_minor") val grossOwed: Long,
    @SerialName("gross_owed_back_minor") val grossOwedBack: Long)

@Serializable data class NotificationRow(val id: String, val kind: String, val title: String, val body: String,
    @SerialName("read_at") val readAt: String? = null, @SerialName("created_at") val createdAt: String)

@Serializable data class ActivityRow(val id: Long, val type: String, @SerialName("created_at") val createdAt: String,
    val reason: String? = null, @SerialName("expense_id") val expenseId: String? = null)

@Serializable data class GroupRow(val id: String, val name: String, val description: String? = null)

@Serializable data class PaymentMethod(val id: String? = null, val provider: String, @SerialName("method_type") val type: String,
    @SerialName("account_holder") val holder: String, @SerialName("account_number") val number: String,
    val nickname: String? = null, val instructions: String? = null, @SerialName("is_default") val isDefault: Boolean = false,
    @SerialName("shared_with_debtors") val shared: Boolean = false)

@Serializable data class WhatsAppTarget(val phone: String? = null, val message: String)
