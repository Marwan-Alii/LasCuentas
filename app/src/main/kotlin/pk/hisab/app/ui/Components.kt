package pk.hisab.app.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pk.hisab.core.formatPkr

@Composable
fun MoneyText(minor: Long, color: Color = HisabColors.Ink, style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.titleMedium) =
    Text(formatPkr(minor), color = color, style = style)

enum class Tone(val fg: Color, val bg: Color) {
    Neutral(HisabColors.Forest, HisabColors.Sage), Pending(HisabColors.Amber, HisabColors.AmberSoft), Problem(HisabColors.Red, HisabColors.RedSoft)
}

@Composable
fun StatusChip(label: String, tone: Tone = Tone.Neutral) =
    Surface(color = tone.bg, shape = Dim.control) { Text(label, color = tone.fg, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) }

@Composable
fun HCard(modifier: Modifier = Modifier, onClick: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    val m = modifier.fillMaxWidth().border(1.dp, HisabColors.Line, Dim.card)
    if (onClick != null) Card(onClick, m, shape = Dim.card, colors = CardDefaults.cardColors(containerColor = HisabColors.Surface)) { Column(Modifier.padding(Dim.md), content = content) }
    else Card(m, shape = Dim.card, colors = CardDefaults.cardColors(containerColor = HisabColors.Surface)) { Column(Modifier.padding(Dim.md), content = content) }
}

@Composable
fun EmptyState(title: String, hint: String, modifier: Modifier = Modifier) = Column(
    modifier.fillMaxWidth().padding(Dim.lg), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Dim.sm)) {
    Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
    Text(hint, color = HisabColors.Muted, textAlign = TextAlign.Center)
}

@Composable
fun ErrorBanner(message: String?, onDismiss: () -> Unit) {
    if (message == null) return
    Surface(color = HisabColors.RedSoft, shape = Dim.control, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(Dim.md), verticalAlignment = Alignment.CenterVertically) {
            Text(message, color = HisabColors.Red, modifier = Modifier.weight(1f))
            TextButton(onDismiss) { Text("Dismiss") }
        }
    }
}

@Composable
fun SectionTitle(text: String) = Text(text, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = Dim.md, bottom = Dim.xs))

/** Masks all but the last 4 characters of an account identifier. */
fun mask(s: String) = if (s.length <= 4) s else "•".repeat(s.length - 4) + s.takeLast(4)

fun copyToClipboard(ctx: Context, label: String, text: String) {
    (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(label, text))
}

/**
 * Opens WhatsApp with a pre-filled message. The user reviews and sends it; we never claim it was
 * delivered. Returns false when WhatsApp is not installed so the caller can say so.
 */
fun openWhatsApp(ctx: Context, phoneDigits: String, message: String): Boolean {
    val uri = Uri.parse("https://wa.me/$phoneDigits?text=" + Uri.encode(message))
    return try { ctx.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("com.whatsapp")); true }
    catch (e: Exception) { try { ctx.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("com.whatsapp.w4b")); true } catch (e2: Exception) { false } }
}
