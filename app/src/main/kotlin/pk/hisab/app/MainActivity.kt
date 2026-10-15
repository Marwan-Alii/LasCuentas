package pk.hisab.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import pk.hisab.app.ui.*

private enum class Tab(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Outlined.Home), Expenses("Expenses", Icons.Outlined.Receipt), Groups("Groups", Icons.Outlined.Group),
    Activity("Activity", Icons.Outlined.Notifications), Profile("Profile", Icons.Outlined.Person)
}

class MainActivity : ComponentActivity() {
    private val vm: HisabViewModel by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { HisabTheme { Root(vm) } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Root(vm: HisabViewModel) {
    val s by vm.state.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(Tab.Home) }
    var adding by rememberSaveable { mutableStateOf(false) }
    var pair by remember { mutableStateOf<Pair<String, String>?>(null) }

    if (!s.sessionKnown) return
    if (!s.signedIn) { AuthScreen(vm, s); return }

    Scaffold(
        topBar = { TopAppBar(title = { Text(if (adding) "Add expense" else tab.label) }, actions = {
            if (!adding) TextButton({ vm.refresh() }) { Text("Refresh") } else TextButton({ adding = false }) { Text("Cancel") } }) },
        bottomBar = { if (!adding) NavigationBar { Tab.entries.forEach { t ->
            NavigationBarItem(tab == t, { tab = t }, { BadgedBox({ if (t == Tab.Activity && s.dashboard.unread > 0) Badge { Text("${s.dashboard.unread}") } }) { Icon(t.icon, t.label) } }, label = { Text(t.label) }) } } },
        floatingActionButton = { if (!adding && tab == Tab.Home) ExtendedFloatingActionButton({ adding = true }, containerColor = HisabColors.Forest, contentColor = HisabColors.Paper) { Text("Add expense") } },
    ) { pad ->
        Surface(Modifier.padding(pad)) {
            if (adding) AddExpenseScreen(vm, s) { adding = false; tab = Tab.Home }
            else when (tab) {
                Tab.Home -> HomeScreen(vm, s, { adding = true }) { d, c -> pair = d to c }
                Tab.Expenses -> ExpensesScreen(vm, s)
                Tab.Groups -> GroupsScreen(vm, s)
                Tab.Activity -> ActivityScreen(vm, s)
                Tab.Profile -> ProfileScreen(vm, s)
            }
        }
    }
    pair?.let { (d, c) -> PairDialog(vm, s, d, c) { pair = null } }
}
