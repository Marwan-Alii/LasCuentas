package pk.hisab.app.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object HisabColors {
    val Forest = Color(0xFF172B27)
    val Paper = Color(0xFFF6F4EE)
    val Sage = Color(0xFFDDE8DF)
    val Amber = Color(0xFFB7791F)
    val AmberSoft = Color(0xFFFBF1DC)
    val Red = Color(0xFFB3261E)
    val RedSoft = Color(0xFFFBE9E7)
    val Ink = Color(0xFF1B2623)
    val Muted = Color(0xFF5E6B67)
    val Line = Color(0xFFD9DDD6)
    val Surface = Color(0xFFFFFFFF)
}

/** Spacing + radius tokens; one radius for cards, one for controls. */
object Dim { val xs = 4.dp; val sm = 8.dp; val md = 16.dp; val lg = 24.dp; val card = RoundedCornerShape(12.dp); val control = RoundedCornerShape(10.dp) }

private val scheme = lightColorScheme(
    primary = HisabColors.Forest, onPrimary = HisabColors.Paper,
    secondary = HisabColors.Sage, onSecondary = HisabColors.Forest,
    background = HisabColors.Paper, onBackground = HisabColors.Ink,
    surface = HisabColors.Surface, onSurface = HisabColors.Ink,
    surfaceVariant = HisabColors.Sage, onSurfaceVariant = HisabColors.Muted,
    error = HisabColors.Red, outline = HisabColors.Line,
)

private val type = Typography(
    headlineSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 14.sp),
    labelSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 12.sp),
)

@Composable
fun HisabTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = scheme, typography = type, content = content)
