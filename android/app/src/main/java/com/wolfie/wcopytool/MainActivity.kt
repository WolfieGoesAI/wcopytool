package com.wolfie.wcopytool

import android.app.PendingIntent
import android.content.*
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.material3.*
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Palette matching the ChipBurner Android app (dark, amber-primary).
private object Pal {
    val ground = Color(0xFF15171A); val card = Color(0xFF1E2125); val raised = Color(0xFF2A2E33)
    val bar = Color(0xFF1B1E21); val line = Color(0xFF3A3F45); val text = Color(0xFFECE8E1)
    val text2 = Color(0xFFA39E95); val amber = Color(0xFFF2A33A); val amberLight = Color(0xFFFFC170)
    val amberDim = Color(0xFF3A2E1A); val onAmber = Color(0xFF1B1408); val uv = Color(0xFF8F86F0)
    val red = Color(0xFFFF9A8B); val redBg = Color(0xFF3A1F1C)
}
private fun appColorScheme() = darkColorScheme(
    primary = Pal.amber, onPrimary = Pal.onAmber, primaryContainer = Pal.amberDim, onPrimaryContainer = Pal.amberLight,
    secondary = Pal.uv, background = Pal.ground, onBackground = Pal.text, surface = Pal.card, onSurface = Pal.text,
    surfaceVariant = Pal.raised, onSurfaceVariant = Pal.text2, outline = Pal.line,
    surfaceContainer = Pal.bar, surfaceContainerHigh = Pal.card, surfaceContainerLow = Pal.ground,
    secondaryContainer = Pal.amberDim, onSecondaryContainer = Pal.amberLight,
    error = Pal.red, errorContainer = Pal.redBg,
)

class MainActivity : ComponentActivity() {
    private lateinit var usb: UsbManager
    private lateinit var reader: UsbReader
    private val logLines = mutableStateListOf<String>()
    private val status = mutableStateOf("Not connected")
    // Operation progress for the bottom bar: null = idle (hidden), <0 = busy/indeterminate, 0..1 = fraction.
    private val progress = mutableStateOf<Float?>(null)
    private fun setProgress(v: Float?) = runOnUiThread { progress.value = v }
    private val ACTION_PERM = "com.wolfie.wcopytool.USB_PERMISSION"

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.action) {
                ACTION_PERM -> {
                    @Suppress("DEPRECATION") val dev = i.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && dev != null) doOpen(dev)
                    else log("USB permission denied")
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> connect()
                UsbManager.ACTION_USB_DEVICE_DETACHED -> { reader.close(); status.value = "Disconnected"; log("device detached") }
            }
        }
    }

    fun log(s: String) = runOnUiThread { logLines.add(0, s); while (logLines.size > 300) logLines.removeAt(logLines.size - 1) }

    fun connect() {
        val dev = reader.findDevice() ?: run { status.value = "No copier found — plug it in via OTG"; return }
        if (usb.hasPermission(dev)) doOpen(dev)
        else usb.requestPermission(dev, PendingIntent.getBroadcast(this, 0, Intent(ACTION_PERM).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE))
    }
    private fun doOpen(dev: UsbDevice) { status.value = reader.open(dev); log(status.value) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        usb = getSystemService(USB_SERVICE) as UsbManager
        reader = UsbReader(usb)
        val filter = IntentFilter(ACTION_PERM).apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED); addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(receiver, filter)
        setContent { MaterialTheme(colorScheme = appColorScheme()) { App() } }
        connect()
    }
    override fun onDestroy() { super.onDestroy(); try { unregisterReceiver(receiver) } catch (_: Exception) {}; reader.close() }
    private fun isSystemDark(): Boolean =
        (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    fun App() {
        val scope = rememberCoroutineScope()
        fun go(block: () -> Unit) {
            scope.launch(Dispatchers.IO) {
                setProgress(-1f)   // busy / indeterminate until an op reports a fraction
                try { block() } catch (e: Exception) { log("error: ${e.message}") } finally { setProgress(null) }
            }
        }

        // shared state
        val freq = remember { mutableStateOf("125000") }
        val keyText = remember { mutableStateOf(Proto.DEFAULT_KEYS.joinToString("\n")) }
        val titles = listOf("125 kHz ID", "HID Prox", "Passwords", "Log")
        val pager = rememberPagerState(pageCount = { titles.size })

        Scaffold(topBar = {
            TopAppBar(title = { Text("wCopyTool — LF", fontSize = 16.sp) }, actions = {
                TextButton(onClick = { connect() }) { Text(if (reader.connected) "Reconnect" else "Connect") }
            })
        }) { pad ->
            Column(Modifier.padding(pad).padding(horizontal = 12.dp).fillMaxSize()) {
                Text(status.value, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.height(6.dp))
                ScrollableTabRow(selectedTabIndex = pager.currentPage, edgePadding = 0.dp) {
                    titles.forEachIndexed { i, t ->
                        Tab(selected = pager.currentPage == i, onClick = { scope.launch { pager.animateScrollToPage(i) } }, text = { Text(t, fontSize = 12.sp) })
                    }
                }
                Spacer(Modifier.height(8.dp))
                HorizontalPager(state = pager, modifier = Modifier.weight(1f).fillMaxWidth()) { page ->
                    Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                        when (page) {
                            0 -> LfIdTab(freq, keyText, ::go)
                            1 -> HidTab(freq, keyText, ::go)
                            2 -> PasswordsTab(keyText)
                            else -> LogTab(logLines)
                        }
                    }
                }
                val p = progress.value
                if (p != null) {
                    Spacer(Modifier.height(6.dp))
                    if (p < 0f) LinearProgressIndicator(Modifier.fillMaxWidth())
                    else LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth())
                    Text(if (p < 0f) "Working…" else "Working… ${(p * 100).toInt()}%", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(4.dp))
                }
            }
        }
    }

    @Composable
    fun LfIdTab(freq: MutableState<String>, keyText: MutableState<String>, go: (() -> Unit) -> Unit) {
        val id = remember { mutableStateOf("0") }
        val protect = remember { mutableStateOf(false) }
        val pwd = remember { mutableStateOf("00000000") }
        val t5Pwd = remember { mutableStateOf("00000000") }
        val emPwd = remember { mutableStateOf("00000000") }
        val bitRev = remember { mutableStateOf(false) }
        val byteRev = remember { mutableStateOf(false) }
        val f = 125000L
        Column {
            HexField("Card number (decimal)", id)
            Row { Btn("Read ID") { go { val v = reader.readEMId(f); if (v != null) { id.value = v.toString(); log("✓ ID $v") } else log("✗ no card") } } }
            Row {
                Btn("Write T5577") { go {
                    val (w1, w2) = Proto.em4100Words(Fmt.parseDecId(id.value))
                    reader.writeCard(longArrayOf(w1, w2), 0x00148040L, protect.value, pwd.value, t5Pwd.value, f, ::log)
                } }
                Spacer(Modifier.width(8.dp))
                Btn("Write EM4305") { go { reader.writeEM4305(Fmt.parseDecId(id.value), protect.value, pwd.value, emPwd.value, f, ::log) } }
            }
            CheckRow("Password-protect with password:", protect); HexField("New password", pwd)
            HexField("T5577 Unlock Password", t5Pwd)
            HexField("EM4305 Unlock Password", emPwd)
            Row {
                Btn("Unlock T5577") { go {
                    val keys = reader.expandKeys(unlockKeys(keyText.value, t5Pwd.value, pwd.value, false), bitRev.value, byteRev.value)
                    applyFound(t5Pwd, reader.unlockT5577(keys, f, ::log) { setProgress(it) })
                } }
                Spacer(Modifier.width(8.dp))
                Btn("Unlock EM4305") { go {
                    val keys = reader.expandKeys(unlockKeys(keyText.value, emPwd.value, pwd.value, true), bitRev.value, byteRev.value)
                    applyFound(emPwd, reader.unlockEM4305(keys, f, ::log) { setProgress(it) })
                } }
            }
            RevRow("Unlock also try:", bitRev, byteRev)
            Spacer(Modifier.height(6.dp))
            SettleRow()
        }
    }

    @Composable
    fun HidTab(freq: MutableState<String>, keyText: MutableState<String>, go: (() -> Unit) -> Unit) {
        val fmt = remember { mutableStateOf(HIDFormat.H10301) }
        val fc = remember { mutableStateOf("0") }
        val cn = remember { mutableStateOf("0") }
        val animal = remember { mutableStateOf(true) }
        val protect = remember { mutableStateOf(false) }
        val pwd = remember { mutableStateOf("00000000") }
        val cur = remember { mutableStateOf("00000000") }
        val bitRev = remember { mutableStateOf(false) }
        val byteRev = remember { mutableStateOf(false) }
        Column {
            Picker("Format", HIDFormat.values().toList(), fmt.value, { it.label }) { fmt.value = it }
            val isFdx = fmt.value == HIDFormat.FDXB
            HexField(if (isFdx) "Country code" else "Facility code", fc)
            HexField(if (isFdx) "National ID (38-bit)" else "Card number", cn)
            if (isFdx) CheckRow("FDX-B animal flag", animal)
            Row {
                Btn("Read HID") { go {
                    val r = reader.readHID(Fmt.parseDec0(freq.value))
                    val f = r?.fmt
                    if (r != null && f != null) { fmt.value = f; fc.value = r.fc.toString(); cn.value = r.cn.toString(); log("✓ ${f.label}  FC=${r.fc} CN=${r.cn}") }
                    else log("✗ no HID card")
                } }
                Spacer(Modifier.width(8.dp))
                Btn("Write") { go {
                    val f = fmt.value
                    val blocks = Proto.lfProxBlocks(f, Fmt.parseDec(fc.value), Fmt.parseDec(cn.value), Fmt.parseDec(cn.value), animal.value)
                    reader.writeCard(blocks, Proto.lfProxConfig(f), protect.value, pwd.value, cur.value, Fmt.parseDec0(freq.value), ::log)
                } }
            }
            CheckRow("Write-protect with password:", protect); HexField("New password", pwd)
            HexField("Current card password", cur)
            Row {
                Btn("Unlock HID → EM") { go {
                    val keys = reader.expandKeys(unlockKeys(keyText.value, cur.value, pwd.value, false), bitRev.value, byteRev.value)
                    applyFound(cur, reader.unlockHID(keys, 1L, Fmt.parseDec0(freq.value), ::log) { setProgress(it) })
                } }
            }
            RevRow("Unlock also try:", bitRev, byteRev)
        }
    }

    @Composable
    fun PasswordsTab(keyText: MutableState<String>) {
        Column {
            Row {
                Btn("Reset to defaults") { keyText.value = Proto.DEFAULT_KEYS.joinToString("\n") }
            }
            Spacer(Modifier.height(6.dp))
            OutlinedTextField(keyText.value, { keyText.value = it }, Modifier.fillMaxWidth().height(220.dp),
                label = { Text("Known passwords (one 8-hex key per line)") }, textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp))
            Spacer(Modifier.height(8.dp))
            Text("password    bit-rev     byte-rev    ascii", fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            val lines = keyText.value.split("\n").mapNotNull { raw ->
                val h = raw.trim().uppercase().replace(" ", "")
                if (h.length == 8 && h.all { it.isDigit() || it in 'A'..'F' })
                    "%-10s  %-10s  %-10s  %s".format(h, Proto.bitReverse32Hex(h), Proto.byteReverseHex(h), Proto.asciiOfHex(h)) else null
            }
            Text(lines.joinToString("\n"), fontFamily = FontFamily.Monospace, fontSize = 12.sp)
        }
    }

    // helpers
    private fun unlockKeys(keyText: String, cur: String, newPwd: String, em: Boolean): List<IntArray> {
        val out = ArrayList<IntArray>()
        fun add(k: IntArray) { if (out.none { it.contentEquals(k) }) out.add(k) }
        add(Proto.fieldKey(cur))
        add(Proto.fieldKey(newPwd))            // also try the New password field (like the Mac app)
        Proto.NORMALIZE.forEach { add(Proto.keyBytes(it)) }
        if (em) Proto.EM4305_NORMALIZE.forEach { add(Proto.keyBytes(it)) }
        keyText.split("\n").forEach { val h = it.trim().replace(" ", ""); if (h.length == 8) add(Proto.keyBytes(h)) }
        return out
    }

    @Composable fun Btn(t: String, onClick: () -> Unit) = Button(onClick, enabled = reader.connected) { Text(t, fontSize = 13.sp) }
    @Composable fun HexField(label: String, s: MutableState<String>) {
        OutlinedTextField(s.value, { s.value = it }, Modifier.fillMaxWidth().padding(vertical = 3.dp),
            label = { Text(label, fontSize = 12.sp) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace))
    }
    @Composable fun CheckRow(label: String, s: MutableState<Boolean>) =
        Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(s.value, { s.value = it }); Text(label, fontSize = 12.sp) }
    // Per-write settle time (ms), editable so the minimum safe value can be found on real hardware.
    @Composable fun SettleRow() {
        val s = remember { mutableStateOf(reader.settleMs.toString()) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Settle (ms):", fontSize = 12.sp); Spacer(Modifier.width(6.dp))
            OutlinedTextField(
                value = s.value,
                onValueChange = { v -> val d = v.filter { it.isDigit() }.take(4); s.value = d; d.toLongOrNull()?.let { reader.settleMs = it } },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp),
                modifier = Modifier.width(96.dp)
            )
        }
    }
    @Composable fun RevRow(label: String, bitRev: MutableState<Boolean>, byteRev: MutableState<Boolean>) =
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, fontSize = 12.sp); Spacer(Modifier.width(6.dp))
            Checkbox(bitRev.value, { bitRev.value = it }); Text("bit-rev", fontSize = 12.sp)
            Checkbox(byteRev.value, { byteRev.value = it }); Text("byte-rev", fontSize = 12.sp)
        }
    @Composable fun <T> Picker(label: String, items: List<T>, sel: T, title: (T) -> String, onPick: (T) -> Unit) {
        var open by remember { mutableStateOf(false) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("$label:", fontSize = 12.sp); Spacer(Modifier.width(6.dp))
            Box {
                OutlinedButton(onClick = { open = true }) { Text(title(sel), fontSize = 12.sp) }
                DropdownMenu(open, { open = false }) {
                    items.forEach { it0 -> DropdownMenuItem(text = { Text(title(it0)) }, onClick = { onPick(it0); open = false }) }
                }
            }
        }
    }
    @Composable fun LogTab(lines: SnapshotStateList<String>) {
        val clip = LocalClipboardManager.current
        val text = lines.joinToString("\n")
        // No verticalScroll here: the pager wraps every page in a scrolling Box already,
        // and nesting two vertical scrollers crashes. SelectionContainer gives long-press copy.
        Column {
            Row {
                TextButton(onClick = { clip.setText(AnnotatedString(text)) }) { Text("Copy all") }
                TextButton(onClick = { lines.clear() }) { Text("Clear log") }
            }
            SelectionContainer {
                Text(text, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
        }
    }
    // Populate a recovered-password field from an unlock result (8-hex key, or 0 when unprotected).
    private fun applyFound(field: MutableState<String>, res: String) {
        if (res.length == 8 && res.all { it.isDigit() || it in 'A'..'F' }) field.value = res
        else if (res == "no password") field.value = "00000000"
    }
}
