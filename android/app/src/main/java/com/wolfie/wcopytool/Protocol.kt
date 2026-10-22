package com.wolfie.wcopytool

// Pure protocol logic for the nsccn "wCopy" USB-HID copier — LF (125 kHz) subset.
// Transport-agnostic: the same byte sequences used by the macOS app, ported to Kotlin.
object Proto {
    const val REPORT_LEN = 64
    // Known VID/PID pairs for the copier.
    val KNOWN = listOf(0x0416 to 0xB030, 0x0416 to 0xB031, 0x2518 to 0x6022, 0x2518 to 0x6018)

    // ---- framing: 01 LEN 00 00 <payload> CHK FE  (CHK = ~sum of bytes [0..3+n]) ----
    fun build(payload: IntArray): ByteArray {
        val n = minOf(payload.size, 0x30)
        val buf = ByteArray(REPORT_LEN)
        buf[0] = 0x01
        buf[1] = ((n + 6) and 0xFF).toByte()
        for (i in 0 until n) buf[4 + i] = (payload[i] and 0xFF).toByte()
        var sum = 0
        for (i in 0..(3 + n)) sum += buf[i].toInt() and 0xFF
        buf[4 + n] = (sum.inv() and 0xFF).toByte()
        buf[5 + n] = 0xFE.toByte()
        return buf
    }

    data class Parsed(val payload: IntArray, val ok: Boolean, val stx: Int, val status: Int)
    fun parse(r: ByteArray): Parsed? {
        if (r.size < 6) return null
        val b0 = r[0].toInt() and 0xFF
        if (b0 != 0x01 && b0 != 0x02) return null
        val len = r[1].toInt() and 0xFF
        if (len < 6 || len > r.size) return null
        val n = len - 6
        if (4 + n + 1 >= r.size) return null
        val payload = IntArray(n) { r[4 + it].toInt() and 0xFF }
        val chk = r[4 + n].toInt() and 0xFF
        var sum = 0
        for (i in 0..(3 + n)) sum += r[i].toInt() and 0xFF
        return Parsed(payload, (sum.inv() and 0xFF) == chk, b0, r[2].toInt() and 0xFF)
    }

    // ---- small helpers ----
    fun u32le(v: Long) = intArrayOf((v and 0xFF).toInt(), ((v shr 8) and 0xFF).toInt(), ((v shr 16) and 0xFF).toInt(), ((v shr 24) and 0xFF).toInt())
    fun u32be(v: Long) = intArrayOf(((v shr 24) and 0xFF).toInt(), ((v shr 16) and 0xFF).toInt(), ((v shr 8) and 0xFF).toInt(), (v and 0xFF).toInt())

    fun hex(b: IntArray) = b.joinToString(" ") { "%02X".format(it) }
    fun keyBytes(hex: String): IntArray {
        val h = hex.trim().replace(" ", "")
        val out = IntArray(4)
        for (i in 0 until 4) { val a = i * 2; if (a + 2 <= h.length) out[i] = h.substring(a, a + 2).toIntOrNull(16) ?: 0 }
        return out
    }
    fun fieldKey(s: String): IntArray {
        val h = s.trim().replace(" ", "")
        return if (h.length == 8 && h.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) keyBytes(h) else intArrayOf(0, 0, 0, 0)
    }
    fun hexJoin(b: IntArray) = b.joinToString("") { "%02X".format(it) }
    fun bitrev4(b: IntArray): IntArray {
        var v = 0L
        for (i in 0 until 4) v = (v shl 8) or (b[i].toLong() and 0xFF)
        var r = 0L
        for (i in 0 until 32) { r = (r shl 1) or (v and 1); v = v shr 1 }
        return u32be(r)
    }
    fun rev4(b: IntArray) = intArrayOf(b[3], b[2], b[1], b[0])
    fun bitReverse32Hex(h: String) = hexJoin(bitrev4(keyBytes(h)))
    fun byteReverseHex(h: String) = hexJoin(rev4(keyBytes(h)))
    fun asciiOfHex(h: String) = keyBytes(h).joinToString("") { if (it in 0x20..0x7E) it.toChar().toString() else "·" }

    // ---- LF command payloads (all begin FF 00 CLASS …) ----
    fun lfRead(freq: Long = 125000) = intArrayOf(0xFF, 0x00, 0x65, 0x05, 0x1E) + u32le(freq) + intArrayOf(0, 0, 0, 0)
    fun lfRFConfig(freq: Long = 125000) = intArrayOf(0xFF, 0x00, 0x66, 0x00, 0x1E) + u32le(freq) + intArrayOf(0x1F, 0x18, 0x01, 0xEF, 0x00, 0x9B, 0x00, 0x86, 0x01)
    fun lfModeCmd(sub: Int, freq: Long = 125000) = intArrayOf(0xFF, 0x00, 0x66, 0x00, 0x1E) + u32le(freq) + intArrayOf(0x00, sub, 0x00, 0x00)
    fun lfT5Write(addr: Int, word: IntArray, pwd: IntArray, freq: Long = 125000) =
        intArrayOf(0xFF, 0x00, 0x66, 0x00, 0x1E) + u32le(freq) + intArrayOf(0x13, 0x00, addr) + word + pwd
    fun lfT5WriteNoPwd(addr: Int, word: IntArray, freq: Long = 125000) =
        intArrayOf(0xFF, 0x00, 0x66, 0x00, 0x1E) + u32le(freq) + intArrayOf(0x12, 0x00, addr) + word
    fun hidReadCmd() = intArrayOf(0xFF, 0x00, 0x6A, 0x01, 0x00, 0x08)
    // EM4305: login (op 0x21) and write-word (op 0x22). EM4100 emulation: word4 = config, words 5/6 = data.
    fun em4305Login(pwd: IntArray, freq: Long = 125000) = intArrayOf(0xFF, 0x00, 0x66, 0x00, 0x1E) + u32le(freq) + intArrayOf(0x21) + pwd
    fun em4305Write(addr: Int, word: IntArray, freq: Long = 125000) = intArrayOf(0xFF, 0x00, 0x66, 0x00, 0x1E) + u32le(freq) + intArrayOf(0x22, addr) + word
    val EM4305_CONFIG = intArrayOf(0xFA, 0x01, 0xA8, 0x00)      // word4 config for EM4100
    val EM4305_NORMALIZE = listOf("00000000", "05D73B9F")

    // ---- replies ----
    fun recEMid(p: Parsed?): Long? {
        val q = p ?: return null
        if (q.payload.size < 6 || q.payload[0] != 0x05) return null
        var id = 0L
        for (i in 1..5) id = (id shl 8) or q.payload[i].toLong()
        return id
    }
    // HID reply: 07 at payload[0], 5-byte raw value at payload[3..7].
    data class HidRead(val raw: Long, val fmt: HIDFormat?, val fc: Long, val cn: Long, val len: Int, val note: String)
    fun hidDecode(p: Parsed?): HidRead? {
        val q = p ?: return null
        if (q.payload.size < 8 || q.payload[0] != 0x07) return null
        var raw = 0L
        for (i in 3..7) raw = (raw shl 8) or q.payload[i].toLong()
        if (raw == 0L) return null
        return decodeHidRaw(raw)
    }
    // Decode a raw HID value → format + FC/CN. The device returns the value WITH the HID framing: for
    // 26..36-bit formats the 0x20 header (bit 37) is set and the start sentinel sits at bit = length, so
    // the real length is the highest set bit below bit 37; 37-bit formats carry no header. This is the
    // exact inverse of the encoders. Several formats can share a length (e.g. 37-bit H10304/H10302), so
    // the note calls out the alternative and flags a parity mismatch.
    fun decodeHidRaw(raw: Long): HidRead {
        val hasHdr = (raw and (1L shl 37)) != 0L
        val len = if (hasHdr) 63 - java.lang.Long.numberOfLeadingZeros(raw and ((1L shl 37) - 1)) else 37
        if (len < 26 || len > 37) return HidRead(raw, null, 0, 0, len, "unknown length")
        val packed = raw and ((1L shl len) - 1)
        fun gf(fb: Int, w: Int) = (packed shr (len - fb - w)) and ((1L shl w) - 1)
        fun pb(pos: Int) = (packed shr (len - 1 - pos)) and 1L
        fun ev(x: Long) = java.lang.Long.bitCount(x).toLong() and 1L
        fun od(x: Long) = (java.lang.Long.bitCount(x).toLong() and 1L) xor 1L
        fun par(ok: Boolean) = if (ok) "" else "  (parity?)"
        return when (len) {
            26 -> HidRead(raw, HIDFormat.H10301, gf(1, 8), gf(9, 16), 26, par(pb(0) == ev(gf(1, 12)) && pb(25) == od(gf(13, 12))))
            33 -> HidRead(raw, HIDFormat.D10202, gf(1, 7), gf(8, 24), 33, par(pb(0) == ev(gf(1, 16)) && pb(32) == od(gf(16, 16))))
            34 -> HidRead(raw, HIDFormat.H10306, gf(1, 16), gf(17, 16), 34, par(pb(0) == ev(gf(1, 16)) && pb(33) == od(gf(17, 16))))
            35 -> HidRead(raw, HIDFormat.C1K35, gf(2, 12), gf(14, 20), 35, "")   // Corp1000 parity is interleaved; not re-checked
            37 -> {
                val ok = pb(0) == ev(gf(1, 18)) && pb(36) == od(gf(18, 18))
                // Parity failure on a 37-bit read usually means it is not really HID — an AWID/Paradox
                // card demodulates to shifting 40-bit garbage this device can't read. Flag that instead
                // of presenting bogus field values.
                val note = if (ok) "  [or H10302 CN=${gf(1, 35)}]" else "  (parity fail — likely AWID/Paradox, not readable by this device)"
                HidRead(raw, HIDFormat.H10304, gf(1, 16), gf(17, 19), 37, note)
            }
            else -> HidRead(raw, null, 0, 0, len, "length $len not decoded")
        }
    }

    // ---- EM4100 (two 32-bit words) ----
    fun em4100Words(id40: Long): Pair<Long, Long> {
        val bits = ArrayList<Int>()
        repeat(9) { bits.add(1) }
        val col = IntArray(4)
        for (n in 0 until 10) {
            val nib = ((id40 shr ((9 - n) * 4)) and 0xF).toInt()
            var row = 0
            for (b in 0 until 4) { val bit = (nib shr (3 - b)) and 1; bits.add(bit); row = row xor bit; col[b] = col[b] xor bit }
            bits.add(row)
        }
        for (b in 0 until 4) bits.add(col[b]); bits.add(0)
        fun pack(from: Int, to: Int): Long { var w = 0L; for (i in from until to) w = (w shl 1) or bits[i].toLong(); return w }
        return Pair(pack(0, 32), pack(32, 64))
    }

    // ---- HID / AWID / Paradox / FDX-B encoders ----
    fun hidWiegand26(fc: Long, cn: Long): Long {
        val f = fc and 0xFF; val c = cn and 0xFFFF
        val top = (f shl 4) or ((c shr 12) and 0xF); val bot = c and 0xFFF
        val ep = java.lang.Long.bitCount(top).toLong() % 2
        val op = (java.lang.Long.bitCount(bot).toLong() + 1) % 2
        return (ep shl 25) or (f shl 17) or (c shl 1) or op
    }
    fun hidWiegand37(fc: Long, cn: Long): Long {
        val f = fc and 0xFFFF; val c = cn and 0x7FFFF
        val frame = (f shl 20) or (c shl 1)
        val top18 = (frame shr 19) and 0x3FFFF; val bot18 = (frame shr 1) and 0x3FFFF
        val ep = java.lang.Long.bitCount(top18).toLong() % 2
        val op = (java.lang.Long.bitCount(bot18).toLong() + 1) % 2
        return (ep shl 36) or frame or op
    }
    // ---- generic Wiegand packer, positions per Proxmark wiegand_formats.c ----
    // Proxmark numbers bit positions 0..len-1 from the MSB (pos 0 = leading bit). We hold the len-bit
    // field in a Long where Proxmark position `pos` is Long bit (len-1-pos), so field/parity math maps
    // straight across. The HID start sentinel + 0x20 header are added the same way add_HID_header does
    // (nothing is added for 37-bit cards).
    private fun ev(x: Long) = java.lang.Long.bitCount(x).toLong() and 1L           // even-parity bit
    private fun od(x: Long) = (java.lang.Long.bitCount(x).toLong() and 1L) xor 1L  // odd-parity bit
    private class Wp(val len: Int) {
        var p = 0L
        fun set(value: Long, firstBit: Int, width: Int) { p = p or ((value and ((1L shl width) - 1)) shl (len - firstBit - width)) }
        fun get(firstBit: Int, width: Int) = (p shr (len - firstBit - width)) and ((1L shl width) - 1)
        fun bit(b: Long, pos: Int) { p = p or ((b and 1L) shl (len - 1 - pos)) }
        fun raw() = if (len == 37) p else (1L shl 37) or (1L shl len) or p
    }
    // HID D10202 33-bit: FC 7, CN 24.
    fun hidD10202(fc: Long, cn: Long): Long { val w = Wp(33); w.set(fc, 1, 7); w.set(cn, 8, 24); w.bit(ev(w.get(1, 16)), 0); w.bit(od(w.get(16, 16)), 32); return w.raw() }
    // HID H10306 34-bit: FC 16, CN 16.
    fun hidH10306(fc: Long, cn: Long): Long { val w = Wp(34); w.set(fc, 1, 16); w.set(cn, 17, 16); w.bit(ev(w.get(1, 16)), 0); w.bit(od(w.get(17, 16)), 33); return w.raw() }
    // HID H10302 37-bit: no facility code, 35-bit card number.
    fun hidH10302(cn: Long): Long { val w = Wp(37); w.set(cn, 1, 35); w.bit(ev(w.get(1, 18)), 0); w.bit(od(w.get(18, 18)), 36); return w.raw() }
    // HID Corporate 1000 35-bit (std): FC 12, CN 20, 3 interleaved parity bits (ported verbatim from Proxmark).
    fun hidC1k35(fc: Long, cn: Long): Long {
        var bot = 0L; var mid = 0L
        bot = bot or ((cn and 0xFFFFF) shl 1)
        bot = bot or ((fc and 0x7FF) shl 21)
        mid = mid or ((fc and 0x800) shr 11)
        mid = mid or (ev((mid and 0x1) xor (bot and 0xB6DB6DB6L)) shl 1)
        bot = bot or od((mid and 0x3) xor (bot and 0x6DB6DB6CL))
        mid = mid or (od((mid and 0x3) xor (bot and 0xFFFFFFFFL)) shl 2)
        val p = (mid shl 32) or (bot and 0xFFFFFFFFL)
        return (1L shl 37) or (1L shl 35) or p
    }
    fun hidValue(fmt: HIDFormat, fc: Long, cn: Long): Long = when (fmt) {
        HIDFormat.H10301 -> 0x2000000000L or (1L shl 26) or hidWiegand26(fc, cn)
        HIDFormat.H10304 -> hidWiegand37(fc, cn)
        HIDFormat.D10202 -> hidD10202(fc, cn)
        HIDFormat.H10306 -> hidH10306(fc, cn)
        HIDFormat.C1K35 -> hidC1k35(fc, cn)
        HIDFormat.H10302 -> hidH10302(cn)
        else -> 0
    }
    fun hidBlocksV(v: Long): LongArray {
        val bits = intArrayOf(0, 0, 0, 1, 1, 1, 0, 1).toMutableList()
        for (i in 43 downTo 0) { val b = ((v shr i) and 1).toInt(); bits.add(if (b == 0) 0 else 1); bits.add(if (b == 0) 1 else 0) }
        val out = LongArray(3)
        for ((i, b) in bits.withIndex()) out[i / 32] = ((out[i / 32] shl 1) or b.toLong()) and 0xFFFFFFFFL
        return out
    }
    fun awid26Blocks(fc: Long, cn: Long): LongArray {
        val data = ArrayList<Int>()
        for (i in 7 downTo 0) data.add(((fc shr i) and 1).toInt())
        for (i in 15 downTo 0) data.add(((cn shr i) and 1).toInt())
        val ep = (0 until 12).sumOf { data[it] } % 2
        val op = ((12 until 24).sumOf { data[it] } + 1) % 2
        val wieg = ArrayList<Int>(); wieg.add(ep); wieg.addAll(data); wieg.add(op)
        val pre = ArrayList<Int>()
        for (i in 7 downTo 0) pre.add((26 shr i) and 1)
        pre.addAll(wieg); while (pre.size < 66) pre.add(0)
        val body = ArrayList<Int>(); var i = 0
        while (i < 66) { val g = pre.subList(i, minOf(i + 3, 66)); body.addAll(g); body.add(if (g.sum() % 2 == 0) 1 else 0); i += 3 }
        val bits = intArrayOf(0, 0, 0, 0, 0, 0, 0, 1).toMutableList(); bits.addAll(body)
        val out = LongArray(3); for ((j, b) in bits.withIndex()) out[j / 32] = ((out[j / 32] shl 1) or b.toLong()) and 0xFFFFFFFFL
        return out
    }
    private fun crc8Maxim(d: IntArray): Int { var crc = 0; for (b in d) { crc = crc xor b; repeat(8) { crc = if (crc and 1 != 0) (crc shr 1) xor 0x8C else crc shr 1 } }; return crc and 0xFF }
    private fun manch2(d: Long): Long { var r = 0L; for (i in 15 downTo 0) { val bit = (d shr i) and 1; r = (r shl 2) or (if (bit != 0L) 0b10L else 0b01L) }; return r }
    fun paradoxBlocks(fc: Long, cn: Long): LongArray {
        val m = IntArray(13); m[0] = 0x0F; m[1] = 0x05; m[2] = 0x55; m[3] = 0x55
        var t = manch2(fc and 0xFF); m[4] = ((t shr 8) and 0xFF).toInt(); m[5] = (t and 0xFF).toInt()
        t = manch2(cn and 0xFFFF); m[6] = ((t shr 24) and 0xFF).toInt(); m[7] = ((t shr 16) and 0xFF).toInt(); m[8] = ((t shr 8) and 0xFF).toInt(); m[9] = (t and 0xFF).toInt()
        val crc = crc8Maxim(m.copyOfRange(1, 10)) xor 0x06
        t = manch2(crc.toLong()); m[10] = ((t shr 8) and 0xFF).toInt(); m[11] = (t and 0xFF).toInt()
        for (i in 1..11) m[i] = ((m[i] shl 4) or (m[i + 1] shr 4)) and 0xFF
        m[11] = m[11] or 0x08; m[11] = m[11] or 0x02
        val out = LongArray(3); for (i in 0 until 12) out[i / 4] = out[i / 4] or (m[i].toLong() shl (8 * (3 - i % 4)))
        return out
    }
    private fun crc16Fdxb(d: IntArray): Int {
        var crc = 0
        for (b in d) { crc = crc xor (b shl 8); repeat(8) { crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF else (crc shl 1) and 0xFFFF } }
        var r = 0; for (i in 0 until 16) r = (r shl 1) or ((crc shr i) and 1); return r and 0xFFFF
    }
    fun fdxbBlocks(country: Long, national: Long, animal: Boolean): LongArray {
        val bs = IntArray(128) { 1 }
        for (i in 0 until 10) bs[i] = 0; bs[10] = 1
        for (k in 0 until 13) bs[19 + 9 * k] = 1
        fun put(s: Int, n: Int, v: Long) { for (i in 0 until n) bs[s + i] = ((v shr i) and 1).toInt() }
        val nat = national and 0x3FFFFFFFFFL
        put(11, 8, nat and 0xFF); put(20, 8, (nat shr 8) and 0xFF); put(29, 8, (nat shr 16) and 0xFF)
        put(38, 8, (nat shr 24) and 0xFF); put(47, 6, (nat shr 32) and 0x3F)
        val cc = country and 0x3FF; put(53, 2, cc and 0x3); put(56, 8, (cc shr 2) and 0xFF)
        bs[65] = 0; for (i in 66 until 73) bs[i] = 0; for (i in 74 until 81) bs[i] = 0
        bs[81] = if (animal) 1 else 0
        fun b8(a: Int): Int { var v = 0; for (j in 0 until 8) v = (v shl 1) or bs[a + j]; return v }
        val raw = IntArray(8) { b8(11 + 9 * it) }
        val crc = crc16Fdxb(raw)
        put(83, 8, (crc and 0xFF).toLong()); put(92, 8, ((crc shr 8) and 0xFF).toLong())
        for (s in intArrayOf(101, 110, 119)) put(s, 8, 0)
        val out = LongArray(4); for (i in 0 until 128) out[i / 32] = ((out[i / 32] shl 1) or bs[i].toLong()) and 0xFFFFFFFFL
        return out
    }
    // Base T5577 config per format (PWD bit 0x10 OR'd in by caller when protecting).
    fun lfProxConfig(fmt: HIDFormat): Long = if (fmt == HIDFormat.FDXB) 0x00098080L else 0x00107060L
    fun lfProxBlocks(fmt: HIDFormat, fc: Long, cn: Long, national: Long, animal: Boolean): LongArray = when (fmt) {
        HIDFormat.AWID26 -> awid26Blocks(fc, cn)
        HIDFormat.PARADOX -> paradoxBlocks(fc, cn)
        HIDFormat.FDXB -> fdxbBlocks(fc, national, animal)
        else -> hidBlocksV(hidValue(fmt, fc, cn))
    }

    // ---- known keys ----
    val NORMALIZE = listOf("C0F5009A", "00000000", "19920427", "1C0B5848", "5469616E")
    val DEFAULT_KEYS = listOf(
        "00000000","51243648","000D8787","19920427","002BCFCF","50524F58","F9DCEBA0","65857569",
        "89A69E60","314159E0","7B3D5C48","AA55BBBB","A5B4C3D2","1C0B5848","00434343","50415353",
        "444E4752","4E457854","44B44CAE","88661858","E9920427","575F4F4B","50520901","20206666",
        "5469616E","576F6C66","C0F5009A","07CEE75D","FEEDBEEF","DEADC0DE","A9EF2AFC","11111111",
        "22222222","33333333","55555555","66666666","77777777","99999999","BBBBBBBB","FFFFFFFF",
        "A0A1A2A3","B0B1B2B3","01234567","12345678","0CB7E7FC","FABADA11","AABBCCDD","0C0D0E0F","01020304"
    )
}

enum class HIDFormat(val label: String) {
    H10301("HID 26-bit (H10301)"),
    D10202("HID 33-bit (D10202)"),
    H10306("HID 34-bit (H10306)"),
    C1K35("HID 35-bit (Corp 1000)"),
    H10302("HID 37-bit (H10302, no FC)"),
    H10304("HID 37-bit (H10304)"),
    AWID26("AWID 26-bit"), PARADOX("Paradox"), FDXB("FDX-B")
}
