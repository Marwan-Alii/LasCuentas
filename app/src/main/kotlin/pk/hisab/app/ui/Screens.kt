package pk.hisab.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import pk.hisab.app.data.*
import pk.hisab.core.*

private fun parseMinor(s: String): Long? = s.trim().replace(",", "").toBigDecimalOrNull()?.let { (it * 100.toBigDecimal()).toBigIntegerExact().toLong() }.takeIf { it != null && it >= 0 }

@Composable
fun Field(value: String, onChange: (String) -> Unit, label: String, modifier: Modifier = Modifier, number: Boolean = false, minLines: Int = 1) =
    OutlinedTextField(value, onChange, label = { Text(label) }, modifier = modifier.fillMaxWidth(), shape = Dim.control, minLines = minLines,
        singleLine = minLines == 1, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = if (number) KeyboardType.Decimal else KeyboardType.Text))

@Composable
fun Screen(vm: HisabViewModel, s: UiState, content: @Composable ColumnScope.() -> Unit) = LazyColumn(Modifier.fillMaxSize().padding(horizontal = Dim.md), verticalArrangement = Arrangement.spacedBy(Dim.sm)) {
    item { Spacer(Modifier.height(Dim.sm)); ErrorBanner(s.error, vm::clearMessages)
        s.info?.let { Text(it, color = HisabColors.Forest, modifier = Modifier.padding(vertical = Dim.xs)) }
        if (s.loading) LinearProgressIndicator(Modifier.fillMaxWidth()) }
    item { Column(verticalArrangement = Arrangement.spacedBy(Dim.sm), content = content); Spacer(Modifier.height(96.dp)) }
}

// ------------------------------------------------------------------ auth
@Composable
fun AuthScreen(vm: HisabViewModel, s: UiState) {
    var signup by remember { mutableStateOf(false) }
    var email by remember { mutableStateOf("") }; var pw by remember { mutableStateOf("") }; var name by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(Dim.lg), verticalArrangement = Arrangement.spacedBy(Dim.sm, Alignment.CenterVertically)) {
        Text("Hisab", style = MaterialTheme.typography.headlineSmall)
        Text("Shared expenses without the awkward reminders.", color = HisabColors.Muted)
        ErrorBanner(s.error, vm::clearMessages)
        s.info?.let { Text(it) }
        if (signup) Field(name, { name = it }, "Your name")
        Field(email, { email = it }, "Email"); Field(pw, { pw = it }, "Password")
        Button({ vm.act(if (signup) "Check your email to verify your address, then sign in." else null) {
            if (signup) vm.repo.signUp(email.trim(), pw, name.trim()) else vm.repo.signIn(email.trim(), pw) } },
            Modifier.fillMaxWidth(), enabled = !s.loading && email.isNotBlank() && pw.length >= 8 && (!signup || name.isNotBlank())) { Text(if (signup) "Create account" else "Sign in") }
        TextButton({ signup = !signup }) { Text(if (signup) "I already have an account" else "Create an account") }
        if (!signup) TextButton({ vm.act("If that address has an account, a reset link is on its way.") { vm.repo.resetPassword(email.trim()) } }, enabled = email.isNotBlank()) { Text("Forgot password") }
    }
}

// ------------------------------------------------------------------ home
@Composable
fun HomeScreen(vm: HisabViewModel, s: UiState, onAdd: () -> Unit, onOpenPair: (String, String) -> Unit) = Screen(vm, s) {
    val d = s.dashboard
    HCard { Text("Net position", color = HisabColors.Muted); MoneyText(d.owedToMe - d.iOwe, style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(Dim.sm))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Column { Text("Owed to you", color = HisabColors.Muted); MoneyText(d.owedToMe, HisabColors.Forest) }
            Column(horizontalAlignment = Alignment.End) { Text("You owe", color = HisabColors.Muted); MoneyText(d.iOwe, if (d.iOwe > 0) HisabColors.Amber else HisabColors.Ink) } } }
    Button(onAdd, Modifier.fillMaxWidth()) { Text("Add expense") }
    if (d.awaitingMyConfirmation > 0) HCard { StatusChip("${d.awaitingMyConfirmation} to confirm", Tone.Pending); Text("People say they paid you. Confirm once the money has arrived.") }

    val owedToMe = s.pairs.filter { it.creditor == s.me && it.outstanding > 0 || it.creditor == s.me && it.awaiting > 0 }
    val iOwe = s.pairs.filter { it.debtor == s.me && it.outstanding > 0 }
    SectionTitle("Money you're owed")
    if (owedToMe.isEmpty()) EmptyState("Nothing outstanding", "When someone owes you, it shows up here.")
    owedToMe.forEach { PairRow(s, it) { onOpenPair(it.debtor, it.creditor) } }
    SectionTitle("Money you owe")
    if (iOwe.isEmpty()) EmptyState("You're all square", "Nothing to pay right now.")
    iOwe.forEach { PairRow(s, it) { onOpenPair(it.debtor, it.creditor) } }

    if (s.suggestions.isNotEmpty()) {
        SectionTitle("Suggested settlements")
        s.suggestions.forEach { g -> HCard(onClick = { onOpenPair(g.from, g.to) }) {
            Text("${s.name(g.from)} → ${s.name(g.to)}: ${formatPkr(g.amount)}", style = MaterialTheme.typography.titleMedium)
            Text("Nets ${formatPkr(g.grossOwed)} owed against ${formatPkr(g.grossOwedBack)} owed back. Both records stay in the ledger.", color = HisabColors.Muted)
        } }
    }
    SectionTitle("Recent expenses")
    if (s.expenses.isEmpty()) EmptyState("No expenses yet", "Add your first one to start tracking.")
    s.expenses.take(5).forEach { ExpenseRowCard(it) }
}

@Composable
fun PairRow(s: UiState, p: PairBalance, onClick: () -> Unit) = HCard(onClick = onClick) {
    val other = if (p.debtor == s.me) p.creditor else p.debtor
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Column { Text(s.name(other), style = MaterialTheme.typography.titleMedium)
            Text("Original ${formatPkr(p.original)} · confirmed ${formatPkr(p.confirmedReceived)}", color = HisabColors.Muted) }
        MoneyText(p.outstanding, if (p.debtor == s.me) HisabColors.Amber else HisabColors.Forest) }
    if (p.awaiting > 0) { Spacer(Modifier.height(Dim.xs)); StatusChip(if (p.hasDispute) "Disputed · ${formatPkr(p.awaiting)}" else "Awaiting confirmation · ${formatPkr(p.awaiting)}", if (p.hasDispute) Tone.Problem else Tone.Pending) }
}

@Composable
fun ExpenseRowCard(e: ExpenseRow) = HCard {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Column { Text(e.title, style = MaterialTheme.typography.titleMedium); Text(e.date, color = HisabColors.Muted) }
        MoneyText(e.total) }
    if (e.status == "voided") StatusChip("Voided", Tone.Problem)
    if (e.unpaid > 0) StatusChip("${formatPkr(e.unpaid)} not yet paid by anyone", Tone.Pending)
}

// ------------------------------------------------------------------ debt detail (report / confirm)
@Composable
fun PairDialog(vm: HisabViewModel, s: UiState, debtor: String, creditor: String, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val pair = s.pairs.firstOrNull { it.debtor == debtor && it.creditor == creditor }
    val iAmDebtor = debtor == s.me
    val reps = s.repayments.filter { it.from == debtor && it.to == creditor }
    val debts = s.debts.filter { it.debtor == debtor && it.creditor == creditor }
    var amount by remember { mutableStateOf("") }; var ref by remember { mutableStateOf("") }; var note by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    var methods by remember { mutableStateOf(listOf<PaymentMethod>()) }
    LaunchedEffect(debtor, creditor) { if (iAmDebtor) methods = runCatching { vm.repo.methodsFor(creditor) }.getOrDefault(emptyList()) }
    AlertDialog(onDismissRequest = onClose, confirmButton = { TextButton(onClose) { Text("Close") } }, title = { Text(s.name(if (iAmDebtor) creditor else debtor)) }, text = {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(Dim.sm)) {
            item { pair?.let {
                Text("Original ${formatPkr(it.original)}"); Text("Confirmed received ${formatPkr(it.confirmedReceived)}")
                if (it.awaiting > 0) Text("Awaiting confirmation ${formatPkr(it.awaiting)}", color = HisabColors.Amber)
                Text("Still outstanding ${formatPkr(it.outstanding)}", style = MaterialTheme.typography.titleMedium) } }
            items(debts) { Text("${it.title}: ${formatPkr(it.outstanding)} of ${formatPkr(it.original)} left", color = HisabColors.Muted) }
            if (iAmDebtor) {
                item { SectionTitle("Pay ${s.name(creditor)}") }
                if (methods.isEmpty()) item { Text("${s.name(creditor)} hasn't shared payment details. Ask them directly.", color = HisabColors.Muted) }
                items(methods) { m -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("${m.nickname ?: m.provider} · ${m.holder}"); Text(m.number, color = HisabColors.Muted) }
                    TextButton({ copyToClipboard(ctx, "Account", m.number); vm.act("Copied ${m.provider} number") {} }) { Text("Copy") } } }
                item { Text("Pay outside Hisab, then report it here. Your balance only drops once ${s.name(creditor)} confirms.", color = HisabColors.Muted)
                    Field(amount, { amount = it }, "Amount paid (PKR)", number = true); Field(ref, { ref = it }, "Transaction reference (optional)"); Field(note, { note = it }, "Note (optional)")
                    Button({ parseMinor(amount)?.let { a -> vm.act("Payment reported. Waiting for ${s.name(creditor)} to confirm.", onClose) {
                        vm.repo.reportPayment(debtor, creditor, a, ref.ifBlank { null }, note.ifBlank { null }) } } },
                        enabled = parseMinor(amount).let { it != null && it > 0 && it <= (pair?.outstanding ?: 0) }) { Text("I've paid this") } }
            } else {
                item { SectionTitle("Reported payments") }
                if (reps.none { it.status == "reported" || it.status == "disputed" }) item { Text("Nothing waiting for you.", color = HisabColors.Muted) }
                items(reps.filter { it.status == "reported" || it.status == "disputed" }) { r -> HCard {
                    Text("${formatPkr(r.reported)} reported ${r.reference?.let { "· ref $it" } ?: ""}"); r.note?.let { Text(it, color = HisabColors.Muted) }
                    Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) {
                        Button({ vm.act("Confirmed ${formatPkr(r.reported)}") { vm.repo.confirmPayment(r.id, r.reported) } }) { Text("Received ${formatPkr(r.reported)}") } }
                    Field(reason, { reason = it }, "Reason (to dispute or reject)")
                    Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) {
                        OutlinedButton({ vm.act("Marked as disputed") { vm.repo.disputePayment(r.id, reason) } }, enabled = reason.isNotBlank() && r.status == "reported") { Text("Dispute") }
                        OutlinedButton({ vm.act("Rejected") { vm.repo.rejectPayment(r.id, reason) } }, enabled = reason.isNotBlank()) { Text("Not received") } } } }
                item { SectionTitle("Cash received") ; Field(amount, { amount = it }, "Cash amount (PKR)", number = true)
                    Button({ parseMinor(amount)?.let { a -> vm.act("Cash recorded", onClose) { vm.repo.recordCash(debtor, creditor, a) } } },
                        enabled = parseMinor(amount).let { it != null && it > 0 && it <= (pair?.outstanding ?: 0) }) { Text("Record cash received") }
                    debts.firstOrNull { it.outstanding > 0 }?.let { d -> OutlinedButton({ vm.act {
                        val t = vm.repo.whatsappTarget(d.debtId)
                        if (t?.phone == null) throw IllegalStateException("No WhatsApp number available for this person.")
                        if (!openWhatsApp(ctx, t.phone, t.message)) throw IllegalStateException("WhatsApp isn't installed on this phone.") } }) { Text("Remind via WhatsApp") } }
                    Text("This opens WhatsApp with a message ready for you to review and send; Hisab can't tell whether you sent it.", color = HisabColors.Muted) }
            }
            item { SectionTitle("History") }
            items(reps) { Text("${formatPkr(it.reported)} · ${it.status}${if (it.status == "confirmed") " (${formatPkr(it.confirmed)})" else ""}", color = HisabColors.Muted) }
        }
    })
}

// ------------------------------------------------------------------ expenses list with search + status filter
@Composable
fun ExpensesScreen(vm: HisabViewModel, s: UiState) {
    var q by remember { mutableStateOf("") }; var onlyOpen by remember { mutableStateOf(false) }
    val open = s.debts.filter { it.outstanding > 0 }.map { it.expenseId }.toSet()
    val list = s.expenses.filter { it.title.contains(q, true) && (!onlyOpen || it.id in open) }
    Screen(vm, s) {
        Field(q, { q = it }, "Search expenses")
        Row(verticalAlignment = Alignment.CenterVertically) { Switch(onlyOpen, { onlyOpen = it }); Spacer(Modifier.width(Dim.sm)); Text("Only with money outstanding") }
        if (list.isEmpty()) EmptyState("No matching expenses", "Try a different search.")
        list.forEach { ExpenseRowCard(it) }
    }
}

// ------------------------------------------------------------------ add expense
private data class DraftItem(val id: String, val name: String, val qty: Int, val price: Long, val sharedBy: Set<PartyId>)

@Composable
fun AddExpenseScreen(vm: HisabViewModel, s: UiState, onDone: () -> Unit) {
    val me = s.me ?: return
    val opId = remember { java.util.UUID.randomUUID().toString() }       // stable across retries of this one save
    var title by remember { mutableStateOf("") }; var itemized by remember { mutableStateOf(false) }
    var total by remember { mutableStateOf("") }; var notes by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf(setOf(me)) }; var groupId by remember { mutableStateOf<String?>(null) }
    var paid by remember { mutableStateOf(mapOf<String, String>()) }   // contributor -> amount text (default: I paid it all)
    var items by remember { mutableStateOf(listOf<DraftItem>()) }
    var iName by remember { mutableStateOf("") }; var iQty by remember { mutableStateOf("1") }; var iPrice by remember { mutableStateOf("") }
    var delivery by remember { mutableStateOf("") }
    var interval by remember { mutableIntStateOf(24) }; var offReminders by remember { mutableStateOf(setOf<String>()) }

    val itemsTotal = items.sumOf { it.qty * it.price } + (parseMinor(delivery) ?: 0)
    val totalMinor = if (itemized) itemsTotal else parseMinor(total) ?: 0
    val contributions: Map<String, Long> = if (paid.isEmpty()) mapOf(me to totalMinor) else paid.mapValues { parseMinor(it.value) ?: 0 }.filterValues { it > 0 }

    // Live preview comes from the SAME engine the server mirrors.
    val preview = runCatching {
        require(picked.isNotEmpty() && totalMinor > 0)
        val spec = if (!itemized) ExpenseSpec.quick("preview", title.ifBlank { "Expense" }, me, totalMinor, picked, contributions)
        else ExpenseSpec("preview", title.ifBlank { "Expense" }, me, picked,
            items = items.map { ExpenseItem(it.id, it.name, it.qty, it.price, AllocationMethod.Equal(it.sharedBy.ifEmpty { picked })) },
            charges = parseMinor(delivery)?.takeIf { it > 0 }?.let { listOf(ExtraCharge("delivery", "Delivery", it, ChargeMethod.Equal(picked))) } ?: emptyList(),
            contributions = contributions)
        spec to ExpenseEngine.compute(spec)
    }
    Screen(vm, s) {
        Field(title, { title = it }, "Title (e.g. Friday Dinner)")
        Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) {
            FilterChip(!itemized, { itemized = false }, { Text("Quick total") }); FilterChip(itemized, { itemized = true }, { Text("Itemized bill") }) }
        if (s.groups.isNotEmpty()) { Text("Group (optional)"); Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) {
            FilterChip(groupId == null, { groupId = null }, { Text("None") }); s.groups.forEach { g -> FilterChip(groupId == g.id, { groupId = g.id }, { Text(g.name) }) } } }
        SectionTitle("Who is involved")
        s.parties.forEach { p -> Row(Modifier.fillMaxWidth().clickable { picked = if (p.id in picked) picked - p.id else picked + p.id }, verticalAlignment = Alignment.CenterVertically) {
            Checkbox(p.id in picked, { picked = if (it) picked + p.id else picked - p.id }); Text(s.name(p.id) + if (p.kind == "guest") " (guest)" else "") } }
        if (!itemized) Field(total, { total = it }, "Total (PKR)", number = true)
        else {
            items.forEach { HCard { Text("${it.name} × ${it.qty} @ ${formatPkr(it.price)} = ${formatPkr(it.qty * it.price)}"); TextButton({ items = items - it }) { Text("Remove") } } }
            HCard { Field(iName, { iName = it }, "Item"); Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) {
                Field(iQty, { iQty = it }, "Qty", Modifier.weight(1f), number = true); Field(iPrice, { iPrice = it }, "Unit price", Modifier.weight(2f), number = true) }
                Text("Shared by: everyone selected above. Untick someone first if they didn't have this item.", color = HisabColors.Muted)
                Button({ val q = iQty.toIntOrNull(); val pr = parseMinor(iPrice)
                    if (q != null && q > 0 && pr != null && iName.isNotBlank()) { items = items + DraftItem(java.util.UUID.randomUUID().toString(), iName.trim(), q, pr, picked); iName = ""; iQty = "1"; iPrice = "" } },
                    enabled = iName.isNotBlank()) { Text("Add item") } }
            Field(delivery, { delivery = it }, "Delivery / tip / tax (shared equally, optional)", number = true)
        }
        SectionTitle("Who paid the bill")
        Text(if (paid.isEmpty()) "You paid all of it." else "Enter what each person paid.", color = HisabColors.Muted)
        TextButton({ paid = if (paid.isEmpty()) picked.associateWith { if (it == me) formatMinor(totalMinor) else "" } else emptyMap() }) { Text(if (paid.isEmpty()) "Split who paid" else "I paid it all") }
        paid.keys.sorted().forEach { id -> Field(paid[id] ?: "", { paid = paid + (id to it) }, "${s.name(id)} paid (PKR)", number = true) }

        SectionTitle("Review")
        preview.getOrNull()?.let { (_, c) ->
            HCard { Text("Total ${formatPkr(c.total)}", style = MaterialTheme.typography.titleMedium)
                c.netPositions.forEach { (p, net) -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("${s.name(p)} · share ${formatPkr(c.shares[p] ?: 0)} · paid ${formatPkr(c.contributions[p] ?: 0)}")
                    Text(if (net >= 0) "gets ${formatPkr(net)}" else "owes ${formatPkr(-net)}", color = if (net >= 0) HisabColors.Forest else HisabColors.Amber) } }
                if (c.unpaid > 0) StatusChip("${formatPkr(c.unpaid)} not yet paid by anyone", Tone.Pending) }
        } ?: preview.exceptionOrNull()?.let { if (totalMinor > 0) Text(it.message ?: "", color = HisabColors.Red) }

        SectionTitle("Reminders")
        Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) { listOf(3, 6, 12, 24).forEach { h -> FilterChip(interval == h, { interval = h }, { Text("${h}h") }) } }
        picked.filter { it != me }.forEach { id -> Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(id !in offReminders, { offReminders = if (it) offReminders - id else offReminders + id }); Spacer(Modifier.width(Dim.sm)); Text("Send reminders to ${s.name(id)}") } }
        Field(notes, { notes = it }, "Notes (optional)", minLines = 2)
        Button({ preview.getOrNull()?.let { (spec, _) ->
            vm.act("Expense saved", onDone) { vm.repo.createExpense(spec.copy(id = "send", remindersDisabledFor = offReminders), groupId, notes.ifBlank { null }, interval, 5, opId) } } },
            Modifier.fillMaxWidth(), enabled = preview.isSuccess && title.isNotBlank() && !s.loading) { Text("Save expense") }
    }
}
private fun formatMinor(m: Long) = if (m % 100 == 0L) (m / 100).toString() else "%d.%02d".format(m / 100, m % 100)

// ------------------------------------------------------------------ groups
@Composable
fun GroupsScreen(vm: HisabViewModel, s: UiState) {
    var name by remember { mutableStateOf("") }; var code by remember { mutableStateOf("") }; var invite by remember { mutableStateOf<String?>(null) }
    var gName by remember { mutableStateOf("") }; var gMail by remember { mutableStateOf("") }; var gPhone by remember { mutableStateOf("") }
    Screen(vm, s) {
        if (s.groups.isEmpty()) EmptyState("No groups yet", "Create one for your room or trip, or join with an invite code.")
        s.groups.forEach { g -> HCard { Text(g.name, style = MaterialTheme.typography.titleMedium); g.description?.let { Text(it, color = HisabColors.Muted) }
            TextButton({ vm.act { invite = vm.repo.createInvite(g.id) } }) { Text("Create invite code") } } }
        invite?.let { HCard { Text("Invite code (valid 72 hours, 10 uses)"); Text(it, style = MaterialTheme.typography.headlineSmall) } }
        SectionTitle("Create a group"); Field(name, { name = it }, "Group name")
        Button({ vm.act("Group created") { vm.repo.createGroup(name.trim(), null) }; name = "" }, enabled = name.isNotBlank()) { Text("Create") }
        SectionTitle("Join with a code"); Field(code, { code = it }, "Invite code")
        Button({ vm.act("Joined") { vm.repo.joinGroup(code.trim()) }; code = "" }, enabled = code.isNotBlank()) { Text("Join") }
        SectionTitle("Add a guest (someone without the app)"); Field(gName, { gName = it }, "Name"); Field(gMail, { gMail = it }, "Email (optional)"); Field(gPhone, { gPhone = it }, "WhatsApp number (optional)", number = true)
        Button({ vm.act("Guest added") { vm.repo.createGuest(gName.trim(), gMail.ifBlank { null }, gPhone.ifBlank { null }) }; gName = ""; gMail = ""; gPhone = "" }, enabled = gName.isNotBlank()) { Text("Add guest") }
        val guests = s.parties.filter { it.kind == "guest" }
        if (guests.isNotEmpty()) { SectionTitle("Claim a guest profile"); Text("If someone created a profile for you, verify your email in Hisab first, then claim it.", color = HisabColors.Muted)
            guests.forEach { g -> OutlinedButton({ vm.act("Profile claimed. Your history is now on your account.") { vm.repo.claimGuest(g.id) } }) { Text("Claim ${g.name}") } } }
    }
}

// ------------------------------------------------------------------ activity + notifications
@Composable
fun ActivityScreen(vm: HisabViewModel, s: UiState) = Screen(vm, s) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text("Notifications (${s.dashboard.unread} unread)", style = MaterialTheme.typography.titleMedium)
        TextButton({ vm.act { vm.repo.markAllRead() } }, enabled = s.dashboard.unread > 0) { Text("Mark all read") } }
    if (s.notifications.isEmpty()) EmptyState("All quiet", "Payment reports, confirmations and reminders appear here.")
    s.notifications.take(30).forEach { n -> HCard(onClick = { if (n.readAt == null) vm.act { vm.repo.markRead(n.id) } }) {
        Row { Text(n.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f)); if (n.readAt == null) StatusChip("New", Tone.Pending) }
        Text(n.body, color = HisabColors.Muted) } }
    SectionTitle("History")
    s.activity.forEach { a -> Text("${a.createdAt.take(16).replace('T', ' ')} · ${a.type.lowercase().replace('_', ' ')}${a.reason?.let { " — $it" } ?: ""}", color = HisabColors.Muted) }
}

// ------------------------------------------------------------------ profile + payment methods
@Composable
fun ProfileScreen(vm: HisabViewModel, s: UiState) {
    var provider by remember { mutableStateOf("") }; var type by remember { mutableStateOf("wallet") }; var holder by remember { mutableStateOf("") }
    var number by remember { mutableStateOf("") }; var nick by remember { mutableStateOf("") }; var share by remember { mutableStateOf(false) }
    Screen(vm, s) {
        SectionTitle("Payment methods")
        Text("Private by default. If you share one, only people who currently owe you can see it.", color = HisabColors.Muted)
        if (s.methods.isEmpty()) EmptyState("No payment methods", "Add Easypaisa, JazzCash, a bank account or anything else.")
        s.methods.forEach { m -> HCard { Text("${m.nickname ?: m.provider}${if (m.isDefault) " · default" else ""}", style = MaterialTheme.typography.titleMedium)
            Text("${m.provider} · ${m.holder} · ${mask(m.number)}", color = HisabColors.Muted); if (m.shared) StatusChip("Shared with people who owe you")
            Row { m.id?.let { id -> TextButton({ vm.act { vm.repo.setDefaultMethod(id) } }, enabled = !m.isDefault) { Text("Make default") }
                TextButton({ vm.act { vm.repo.deletePaymentMethod(id) } }) { Text("Remove") } } } } }
        HCard { Text("Add a method", style = MaterialTheme.typography.titleMedium)
            Field(provider, { provider = it }, "Provider (Easypaisa, HBL, anything)")
            Row(horizontalArrangement = Arrangement.spacedBy(Dim.sm)) { listOf("wallet", "bank", "other").forEach { t -> FilterChip(type == t, { type = t }, { Text(t) }) } }
            Field(holder, { holder = it }, "Account holder name"); Field(number, { number = it }, "Account / wallet number / IBAN"); Field(nick, { nick = it }, "Nickname (optional)")
            Row(verticalAlignment = Alignment.CenterVertically) { Switch(share, { share = it }); Spacer(Modifier.width(Dim.sm)); Text("Show to people who owe me") }
            Button({ vm.act("Saved") { vm.repo.addPaymentMethod(PaymentMethod(provider = provider.trim(), type = type, holder = holder.trim(), number = number.trim(), nickname = nick.ifBlank { null }, shared = share)) }
                provider = ""; holder = ""; number = ""; nick = "" }, enabled = provider.isNotBlank() && holder.isNotBlank() && number.isNotBlank()) { Text("Save method") } }
        SectionTitle("Account")
        Text("Hisab records payments; it never moves money between accounts.", color = HisabColors.Muted)
        OutlinedButton({ vm.signOut() }) { Text("Sign out") }
    }
}
