package pk.hisab.app.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pk.hisab.app.data.*

data class UiState(
    val signedIn: Boolean = false, val sessionKnown: Boolean = false, val loading: Boolean = false, val error: String? = null, val info: String? = null,
    val me: String? = null, val dashboard: Dashboard = Dashboard(), val parties: List<PartyRow> = emptyList(),
    val expenses: List<ExpenseRow> = emptyList(), val debts: List<DebtBalance> = emptyList(), val pairs: List<PairBalance> = emptyList(),
    val repayments: List<RepaymentRow> = emptyList(), val suggestions: List<Suggestion> = emptyList(),
    val notifications: List<NotificationRow> = emptyList(), val activity: List<ActivityRow> = emptyList(),
    val groups: List<GroupRow> = emptyList(), val methods: List<PaymentMethod> = emptyList(),
) { fun name(id: String) = if (id == me) "You" else parties.firstOrNull { it.id == id }?.name ?: "Someone" }

class HisabViewModel : ViewModel() {
    val repo = Repo()
    private val _s = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _s.asStateFlow()

    init {
        if (repo.configured) viewModelScope.launch {
            repo.auth.sessionStatus.collect { st ->
                val ok = st is SessionStatus.Authenticated
                _s.update { it.copy(signedIn = ok, sessionKnown = st !is SessionStatus.Initializing) }
                if (ok) refresh()
            }
        } else _s.update { it.copy(sessionKnown = true, error = "This build has no Supabase URL/key. See README → Configure the app.") }
    }

    fun clearMessages() = _s.update { it.copy(error = null, info = null) }

    fun refresh() = viewModelScope.launch {
        _s.update { it.copy(loading = true) }
        try {
            val me = async { repo.myParty() }; val d = async { repo.dashboard() }; val p = async { repo.parties() }
            val e = async { repo.expenses() }; val db = async { repo.debts() }; val pb = async { repo.pairs() }
            val r = async { repo.repayments() }; val sg = async { repo.suggestions() }; val n = async { repo.notifications() }
            val a = async { repo.activity() }; val g = async { repo.groups() }; val m = async { repo.paymentMethods() }
            _s.update { it.copy(me = me.await(), dashboard = d.await(), parties = p.await(), expenses = e.await(), debts = db.await(), pairs = pb.await(),
                repayments = r.await(), suggestions = sg.await(), notifications = n.await(), activity = a.await(), groups = g.await(), methods = m.await(), loading = false) }
        } catch (e: Exception) {
            // Offline or server problem: keep what we already show, say so, and let the user retry.
            _s.update { it.copy(loading = false, error = "Couldn't refresh (${e.message ?: "offline"}). Showing last loaded data.") }
        }
    }

    /** Runs a server action, shows the server's own error text on failure, and refreshes on success. */
    fun act(success: String? = null, onDone: (() -> Unit)? = null, block: suspend () -> Unit) = viewModelScope.launch {
        _s.update { it.copy(loading = true, error = null) }
        try { block(); _s.update { it.copy(info = success) }; refresh().join(); onDone?.invoke() }
        catch (e: Exception) { _s.update { it.copy(loading = false, error = e.message ?: "Something went wrong") } }
    }

    fun signOut() = act { repo.signOut(); _s.update { UiState(sessionKnown = true) } }
}
