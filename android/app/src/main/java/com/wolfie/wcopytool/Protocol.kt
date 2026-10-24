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
        fun gnl(bits: IntArray): Long { var r = 0L; for (p in bits) r = (r shl 1) or (if (p in 0 until len) (packed shr (len - 1 - p)) and 1L else 0L); return r }
        fun ev(x: Long) = java.lang.Long.bitCount(x).toLong() and 1L
        fun od(x: Long) = (java.lang.Long.bitCount(x).toLong() and 1L) xor 1L
        fun par(ok: Boolean) = if (ok) "" else "  (parity?)"
        // Re-encode a candidate and check it reproduces the exact value read — used for the parity-less
        // lengths (Tecom27 / ADT31 / Corp1000) so a write-only/unknown card's FSK-demod noise that lands
        // at one of those lengths isn't reported as a confident (wrong) decode.
        fun verify(fmt: HIDFormat, fc: Long, cn: Long) = hidValue(fmt, fc, cn) == raw
        val undec = "%d-bit raw %X — could not be validated; likely a write-only/unknown card (FDX-A/AWID/Paradox/ASK). Verify on an external reader.".format(len, raw)
        return when (len) {
            26 -> HidRead(raw, HIDFormat.H10301, gf(1, 8), gf(9, 16), 26, par(pb(0) == ev(gf(1, 12)) && pb(25) == od(gf(13, 12))))
            27 -> { val fc = gnl(intArrayOf(15,19,24,23,22,18,6,10,14,3,2)); val cn = gnl(intArrayOf(0,1,13,12,9,26,20,16,17,21,25,7,8,11,4,5)); if (verify(HIDFormat.TECOM27, fc, cn)) HidRead(raw, HIDFormat.TECOM27, fc, cn, 27, "") else HidRead(raw, null, 0, 0, 27, undec) }
            28 -> { val ok = pb(0) == ev(gf(1,13)) && pb(2) == od(gnl(intArrayOf(4,5,7,8,10,11,13,14,16,17,19,20,22,23,25,26))) && pb(27) == od(gf(0,27)); HidRead(raw, HIDFormat.W2804, gf(4,8), gf(12,15), 28, par(ok)) }
            30 -> HidRead(raw, HIDFormat.ATSW30, gf(1,12), gf(13,16), 30, par(pb(0) == ev(gf(1,12)) && pb(29) == od(gf(13,16))))
            31 -> { val fc = gf(1,4); val cn = gf(5,23); if (verify(HIDFormat.ADT31, fc, cn)) HidRead(raw, HIDFormat.ADT31, fc, cn, 31, "") else HidRead(raw, null, 0, 0, 31, undec) }
            32 -> if (pb(1) == 1L && pb(0) == ev(gf(1,16)) && pb(31) == od(gf(14,17))) HidRead(raw, HIDFormat.KASTLE, gf(7,8), gf(15,16), 32, "") else HidRead(raw, null, 0, 0, 32, "32-bit — not Kastle; unsupported format")
            33 -> HidRead(raw, HIDFormat.D10202, gf(1, 7), gf(8, 24), 33, par(pb(0) == ev(gf(1, 16)) && pb(32) == od(gf(16, 16))))
            34 -> HidRead(raw, HIDFormat.H10306, gf(1, 16), gf(17, 16), 34, par(pb(0) == ev(gf(1, 16)) && pb(33) == od(gf(17, 16))))
            35 -> { val fc = gf(2,12); val cn = gf(14,20); if (verify(HIDFormat.C1K35, fc, cn)) HidRead(raw, HIDFormat.C1K35, fc, cn, 35, "") else HidRead(raw, null, 0, 0, 35, undec) }
            36 -> if (pb(0) == ev(gf(1,17)) && pb(35) == od(gf(18,17))) HidRead(raw, HIDFormat.C15001, gf(11,8), gf(19,16), 36, "  OEM=${gf(1,10)}") else HidRead(raw, HIDFormat.S12906, gf(1,8), gf(11,24), 36, "")
            37 -> {
                val ok = pb(0) == ev(gf(1, 18)) && pb(36) == od(gf(18, 18))
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
    // Proxmark numbers bit positions 0..len-1 from the MSB (pos 0 = leading bit). Positions outside
    // [0,len) are ignored (some formats over-specify a width); linear + nonlinear fields are placed
    // MSB-first. raw() adds the HID start sentinel + 0x20 header (nothing is added for 37-bit cards).
    private fun ev(x: Long) = java.lang.Long.bitCount(x).toLong() and 1L           // even-parity bit
    private fun od(x: Long) = (java.lang.Long.bitCount(x).toLong() and 1L) xor 1L  // odd-parity bit
    private class Wp(val len: Int) {
        var p = 0L
        fun bit(b: Long, pos: Int) { if (pos in 0 until len) p = p or ((b and 1L) shl (len - 1 - pos)) }
        fun bitAt(pos: Int) = if (pos in 0 until len) (p shr (len - 1 - pos)) and 1L else 0L
        fun set(v: Long, firstBit: Int, width: Int) { for (i in 0 until width) bit((v shr (width - 1 - i)) and 1L, firstBit + i) }
        fun get(firstBit: Int, width: Int): Long { var r = 0L; for (i in 0 until width) r = (r shl 1) or bitAt(firstBit + i); return r }
        fun setNL(v: Long, bits: IntArray) { for ((i, pos) in bits.withIndex()) bit((v shr (bits.size - 1 - i)) and 1L, pos) }
        fun getNL(bits: IntArray): Long { var r = 0L; for (pos in bits) r = (r shl 1) or bitAt(pos); return r }
        fun raw() = if (len == 37) p else (1L shl 37) or (1L shl len) or p
    }
    // ---- HID (read + write on this device) ----
    fun hidD10202(fc: Long, cn: Long): Long { val w = Wp(33); w.set(fc, 1, 7); w.set(cn, 8, 24); w.bit(ev(w.get(1, 16)), 0); w.bit(od(w.get(16, 16)), 32); return w.raw() }
    fun hidH10306(fc: Long, cn: Long): Long { val w = Wp(34); w.set(fc, 1, 16); w.set(cn, 17, 16); w.bit(ev(w.get(1, 16)), 0); w.bit(od(w.get(17, 16)), 33); return w.raw() }
    fun hidH10302(cn: Long): Long { val w = Wp(37); w.set(cn, 1, 35); w.bit(ev(w.get(1, 18)), 0); w.bit(od(w.get(18, 18)), 36); return w.raw() }
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
    // ---- set A: 27..36-bit HID/FSK Wiegand (ported from Proxmark wiegand_formats.c) ----
    fun hidTecom27(fc: Long, cn: Long): Long { val w = Wp(27); w.setNL(fc, intArrayOf(15,19,24,23,22,18,6,10,14,3,2)); w.setNL(cn, intArrayOf(0,1,13,12,9,26,20,16,17,21,25,7,8,11,4,5)); return w.raw() }
    fun hid2804W(fc: Long, cn: Long): Long { val w = Wp(28); w.set(fc,4,8); w.set(cn,12,15); w.bit(od(w.getNL(intArrayOf(4,5,7,8,10,11,13,14,16,17,19,20,22,23,25,26))),2); w.bit(ev(w.get(1,13)),0); w.bit(od(w.get(0,27)),27); return w.raw() }
    fun hidATSW30(fc: Long, cn: Long): Long { val w = Wp(30); w.set(fc,1,12); w.set(cn,13,16); w.bit(ev(w.get(1,12)),0); w.bit(od(w.get(13,16)),29); return w.raw() }
    fun hidADT31(fc: Long, cn: Long): Long { val w = Wp(31); w.set(fc,1,4); w.set(cn,5,23); return w.raw() }
    fun hidKastle(fc: Long, cn: Long): Long { val w = Wp(32); w.bit(1,1); w.set(0,2,5); w.set(fc,7,8); w.set(cn,15,16); w.bit(ev(w.get(1,16)),0); w.bit(od(w.get(14,17)),31); return w.raw() }
    fun hidC15001(fc: Long, cn: Long): Long { val w = Wp(36); w.set(900,1,10); w.set(fc,11,8); w.set(cn,19,16); w.bit(ev(w.get(1,17)),0); w.bit(od(w.get(18,17)),35); return w.raw() }
    fun hidS12906(fc: Long, cn: Long): Long { val w = Wp(36); w.set(fc,1,8); w.set(0,9,2); w.set(cn,11,24); w.bit(od(w.get(1,17)),0); w.bit(od(w.get(17,18)),35); return w.raw() }
    fun hidValue(fmt: HIDFormat, fc: Long, cn: Long): Long = when (fmt) {
        HIDFormat.H10301 -> 0x2000000000L or (1L shl 26) or hidWiegand26(fc, cn)
        HIDFormat.H10304 -> hidWiegand37(fc, cn)
        HIDFormat.D10202 -> hidD10202(fc, cn)
        HIDFormat.H10306 -> hidH10306(fc, cn)
        HIDFormat.C1K35 -> hidC1k35(fc, cn)
        HIDFormat.H10302 -> hidH10302(cn)
        HIDFormat.TECOM27 -> hidTecom27(fc, cn)
        HIDFormat.W2804 -> hid2804W(fc, cn)
        HIDFormat.ATSW30 -> hidATSW30(fc, cn)
        HIDFormat.ADT31 -> hidADT31(fc, cn)
        HIDFormat.KASTLE -> hidKastle(fc, cn)
        HIDFormat.C15001 -> hidC15001(fc, cn)
        HIDFormat.S12906 -> hidS12906(fc, cn)
        else -> 0
    }
    // ---- bit helpers for the non-HID LF encoders ----
    private fun bitsMSB(v: Long, n: Int): IntArray = IntArray(n) { ((v shr (n - 1 - it)) and 1L).toInt() }
    private fun packBlocks(bits: List<Int>, n: Int): LongArray { val out = LongArray(n); for ((j, b) in bits.withIndex()) if (j / 32 < n) out[j / 32] = ((out[j / 32] shl 1) or b.toLong()) and 0xFFFFFFFFL; return out }
    private fun wiegandAddParity(src: List<Int>): List<Int> { val h = src.size / 2; val epp = src.subList(0, h).sum() and 1; val opp = (src.subList(h, src.size).sum() and 1) xor 1; val r = ArrayList<Int>(); r.add(epp); r.addAll(src); r.add(opp); return r }
    private fun addParityOdd(src: List<Int>, sourceLen: Int, pLen: Int): List<Int> {
        val dest = ArrayList<Int>(); var word = 0
        while (word < sourceLen) { var wd = 0; for (bit in 0 until pLen - 1) { val i = word + bit; val s = if (i < src.size) src[i] else 0; wd = (wd shl 1) or s; dest.add(s) }; dest.add(java.lang.Integer.bitCount(wd) and 1); word += pLen - 1 }
        return dest
    }
    private fun dec2bcd(dec: Long): Long { var d = dec; var r = 0L; var s = 0; while (d > 0) { r = r or ((d % 10) shl s); d /= 10; s += 4 }; return r }
    fun hidBlocksV(v: Long): LongArray {
        val bits = intArrayOf(0, 0, 0, 1, 1, 1, 0, 1).toMutableList()
        for (i in 43 downTo 0) { val b = ((v shr i) and 1).toInt(); bits.add(if (b == 0) 0 else 1); bits.add(if (b == 0) 1 else 0) }
        val out = LongArray(3)
        for ((i, b) in bits.withIndex()) out[i / 32] = ((out[i / 32] shl 1) or b.toLong()) and 0xFFFFFFFFL
        return out
    }
    // AWID 26/34-bit (FSK2a RF/50), per Proxmark getAWIDBits. The group parity bit is 1 when the group
    // sum is EVEN — the polarity that reads back on real hardware (verified; plain XOR does not register).
    // WRITE-ONLY on this device.
    fun awidBlocks(fmtlen: Int, fc: Long, cn: Long): LongArray {
        val data = ArrayList<Int>()
        bitsMSB(fc, 8).forEach { data.add(it) }
        bitsMSB(cn, if (fmtlen == 34) 24 else 16).forEach { data.add(it) }
        val pre = ArrayList<Int>(); bitsMSB(fmtlen.toLong(), 8).forEach { pre.add(it) }; pre.addAll(wiegandAddParity(data))
        while (pre.size < 66) pre.add(0)
        val body = ArrayList<Int>(); var i = 0
        while (i < 66) { val g = pre.subList(i, minOf(i + 3, 66)); body.addAll(g); body.add(if (g.sum() % 2 == 0) 1 else 0); i += 3 }
        val bits = ArrayList<Int>(); bits.addAll(listOf(0, 0, 0, 0, 0, 0, 0, 1)); bits.addAll(body)
        return packBlocks(bits, 3)
    }
    // ioProx (FSK2a RF/64) — 64-bit, per Proxmark getIOProxBits. version defaults to 1.
    fun ioproxBlocks(version: Long, fc: Long, cn: Long): LongArray {
        val pre = IntArray(64); var pos = 9
        fun put(v: Long, n: Int) { val b = bitsMSB(v, n); for (i in 0 until n) pre[pos + i] = b[i]; pos += n }
        put(0xF0, 8); pre[pos] = 1; pos++
        put(fc and 0xFF, 8); pre[pos] = 1; pos++
        put(version and 0xFF, 8); pre[pos] = 1; pos++
        put((cn shr 8) and 0xFF, 8); pre[pos] = 1; pos++
        put(cn and 0xFF, 8); pre[pos] = 1; pos++
        var crc = 0L
        for (i in 1 until 6) { var byte = 0L; for (k in 0 until 8) byte = (byte shl 1) or pre[9 * i + k].toLong(); crc += byte }
        crc = (0xFF - (crc and 0xFF)) and 0xFF
        put(crc, 8); pre[pos] = 1; pre[pos + 1] = 1
        return packBlocks(pre.toList(), 2)
    }
    // Pyramid / Farpointe (FSK2a RF/50) — 128-bit, per Proxmark getPyramidBits.
    fun pyramidBlocks(fc: Long, cn: Long): LongArray {
        val pre = IntArray(128); pre[79] = 1
        val wp = wiegandAddParity((bitsMSB(fc, 8).toList() + bitsMSB(cn, 16).toList()))
        for ((i, b) in wp.withIndex()) pre[80 + i] = b
        val body = addParityOdd(pre.toList().subList(8, 128), 102, 8)
        val out = IntArray(128); for ((i, b) in body.withIndex()) out[8 + i] = b
        val cs = IntArray(13); for (i in 0 until 13) { var byte = 0; for (k in 0 until 8) byte = (byte shl 1) or out[16 + i * 8 + k]; cs[i] = byte }
        bitsMSB(crc8Maxim(cs).toLong(), 8).let { for (i in it.indices) out[120 + i] = it[i] }
        return packBlocks(out.toList(), 4)
    }
    // Destron / FDX-A FECAVA (FSK2 RF/50) — 96-bit, per Proxmark. uid: up to 5 bytes.
    fun destronBlocks(uid: IntArray): LongArray {
        val dataEx = IntArray(12 + 24); val n = minOf(uid.size, 5)
        for (i in 0 until n) { val opb = java.lang.Integer.bitCount(uid[i] and 0xFF) and 1; dataEx[i + 1] = (uid[i] or (opb shl 7)).inv() and 0xFF }
        val blk = LongArray(4)
        for (i in 0 until 3) blk[i + 1] = manch2((dataEx[i * 2].toLong() shl 8) + dataEx[i * 2 + 1].toLong())
        blk[1] = (blk[1] and 0xFFFFL) or 0xAAE20000L
        return longArrayOf(blk[1], blk[2], blk[3])
    }
    // Viking (Manchester RF/32) — 64-bit: 0xF2 preamble, 32-bit id, XOR checksum.
    fun vikingBlocks(id: Long): LongArray {
        val idv = id and 0xFFFFFFFFL
        val chk = ((idv shr 24) and 0xFF) xor ((idv shr 16) and 0xFF) xor ((idv shr 8) and 0xFF) xor (idv and 0xFF) xor 0xF2L xor 0xA8L
        val raw = (0xF2L shl 56) or (idv shl 8) or chk
        return longArrayOf((raw shr 32) and 0xFFFFFFFFL, raw and 0xFFFFFFFFL)
    }
    // Visa2000 (Manchester RF/64 +ST) — 96-bit.
    fun visa2000Blocks(id: Long): LongArray {
        val idv = id and 0xFFFFFFFFL
        fun chksum(v: Long): Long { var s = 0L; var i = 0; while (i < 32) { s = s xor ((v shr i) and 0xF); i += 4 }; return s and 0xF }
        val lut = longArrayOf(0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0)
        var par = 0L; for (k in 0 until 8) par = par or (lut[((idv shr (28 - 4 * k)) and 0xF).toInt()] shl (7 - k))
        return longArrayOf(0x56495332L, idv, (par shl 4) or chksum(idv))
    }
    // Noralsy (Manchester RF/32 +ST) — 96-bit, per Proxmark getnoralsyBits.
    fun noralsyBlocks(id: Long, year: Long): LongArray {
        fun ck(bits: IntArray, len: Int): Long { var s = 0L; var i = 0; while (i < len) { var nib = 0L; for (k in 0 until 4) nib = (nib shl 1) or bits[i + k].toLong(); s = s xor nib; i += 4 }; return s and 0xF }
        val bits = IntArray(96)
        bitsMSB(0xBB0214FFL, 32).let { for (i in 0 until 32) bits[i] = it[i] }
        val idb = dec2bcd(id); val yb = dec2bcd(year) and 0xFF
        bitsMSB((idb and 0xFFF0000L) shr 16, 12).let { for (i in it.indices) bits[32 + i] = it[i] }
        bitsMSB(yb, 8).let { for (i in it.indices) bits[44 + i] = it[i] }
        bitsMSB((idb and 0x000FF00L) shr 8, 8).let { for (i in it.indices) bits[56 + i] = it[i] }
        bitsMSB(idb and 0xFF, 8).let { for (i in it.indices) bits[64 + i] = it[i] }
        bitsMSB(ck(bits.copyOfRange(32, 96), 40), 4).let { for (i in it.indices) bits[72 + i] = it[i] }
        bitsMSB(ck(bits, 76), 4).let { for (i in it.indices) bits[76 + i] = it[i] }
        return packBlocks(bits.toList(), 3)
    }
    // Presco (Manchester RF/32 +ST) — 128-bit: 0x10D00000 preamble, 2×0, fullcode = (site<<24)|user.
    fun prescoBlocks(fc: Long, cn: Long): LongArray = longArrayOf(0x10D00000L, 0, 0, ((fc and 0xFF) shl 24) or (cn and 0xFFFF))
    // Parse a hex string (spaces allowed) into bytes, capped at `max`.
    fun hexBytes(s: String, max: Int): IntArray {
        val h = s.replace("0x", "", true).filter { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        val out = ArrayList<Int>(); var i = 0
        while (i + 1 < h.length + 1 && out.size < max) { val j = minOf(i + 2, h.length); h.substring(i, j).toIntOrNull(16)?.let { out.add(it) }; i = j; if (i >= h.length) break }
        return out.toIntArray()
    }
    // Raw clone: pack arbitrary hex into big-endian 32-bit blocks; config from a modulation preset.
    fun rawCloneBlocks(hex: String): LongArray {
        val bytes = hexBytes(hex, 64); if (bytes.isEmpty()) return LongArray(0)
        val out = ArrayList<Long>(); var i = 0
        while (i < bytes.size) { var w = 0L; for (k in 0 until 4) w = (w shl 8) or (if (i + k < bytes.size) bytes[i + k].toLong() else 0L); out.add(w); i += 4 }
        return out.toLongArray()
    }
    fun rawCloneConfig(modIndex: Int, nBlocks: Int): Long {
        val n = maxOf(nBlocks, 1).toLong()
        val base: Long; val st: Long
        when (modIndex) {
            1 -> { base = 0x00147000L; st = 0 }      // FSK2a RF/64
            2 -> { base = 0x00105000L; st = 0 }      // FSK2  RF/50
            3 -> { base = 0x00088000L; st = 0 }      // Manchester RF/32
            4 -> { base = 0x00088000L; st = 0x08 }   // Manchester RF/32 +ST
            5 -> { base = 0x000C8000L; st = 0 }      // Manchester RF/40
            6 -> { base = 0x00148000L; st = 0x08 }   // Manchester RF/64 +ST
            7 -> { base = 0x00090000L; st = 0 }      // Biphase RF/32
            8 -> { base = 0x00110000L; st = 0 }      // Biphase RF/50
            else -> { base = 0x00107000L; st = 0 }   // FSK2a RF/50
        }
        return base or (n shl 5) or st
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
    fun lfProxConfig(fmt: HIDFormat): Long = when (fmt) {
        HIDFormat.FDXB_A0, HIDFormat.FDXB_A1 -> 0x00098080L   // DIPHASE RF/32 (128-bit FDX-B)
        HIDFormat.IOPROX -> 0x00147040L                       // FSK2a RF/64
        HIDFormat.PYRAMID -> 0x00107080L                      // FSK2a RF/50, 4 blocks
        HIDFormat.DESTRON -> 0x00105060L                      // FSK2  RF/50
        HIDFormat.VIKING -> 0x00088040L                       // Manchester RF/32
        HIDFormat.VISA2000 -> 0x00148068L                     // Manchester RF/64 +ST
        HIDFormat.NORALSY -> 0x00088068L                      // Manchester RF/32 +ST
        HIDFormat.PRESCO -> 0x00088088L                       // Manchester RF/32 +ST, 4 blocks
        else -> 0x00107060L                                   // FSK2a RF/50 (HID / AWID / Paradox)
    }
    // Blocks for an FC/CN format. Destron (UID hex) and Raw clone are handled by the caller (UI strings).
    fun lfProxBlocks(fmt: HIDFormat, fc: Long, cn: Long, national: Long): LongArray = when (fmt) {
        HIDFormat.AWID26 -> awidBlocks(26, fc, cn)
        HIDFormat.AWID34 -> awidBlocks(34, fc, cn)
        HIDFormat.PARADOX -> paradoxBlocks(fc, cn)
        HIDFormat.PYRAMID -> pyramidBlocks(fc, cn)
        HIDFormat.IOPROX -> ioproxBlocks(1, fc, cn)
        HIDFormat.VIKING -> vikingBlocks(cn)
        HIDFormat.VISA2000 -> visa2000Blocks(cn)
        HIDFormat.NORALSY -> noralsyBlocks(cn, 2000)
        HIDFormat.PRESCO -> prescoBlocks(fc, cn)
        HIDFormat.FDXB_A0 -> fdxbBlocks(fc, national, false)
        HIDFormat.FDXB_A1 -> fdxbBlocks(fc, national, true)
        HIDFormat.H10302 -> hidBlocksV(hidH10302(national and 0x7FFFFFFFFL))
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
    TECOM27("Tecom 27-bit"),
    W2804("2804 Wiegand 28-bit"),
    ATSW30("ATS Wiegand 30-bit"),
    ADT31("HID ADT 31-bit"),
    KASTLE("Kastle 32-bit"),
    D10202("HID 33-bit (D10202)"),
    H10306("HID 34-bit (H10306)"),
    C1K35("HID 35-bit (Corp 1000)"),
    C15001("HID KeyScan C15001 36-bit"),
    S12906("HID Simplex S12906 36-bit"),
    H10302("HID 37-bit (H10302, no FC)"),
    H10304("HID 37-bit (H10304)"),
    AWID26("AWID 26-bit"),
    AWID34("AWID 34-bit"),
    PARADOX("Paradox"),
    PYRAMID("Pyramid (Farpointe)"),
    IOPROX("ioProx (Kantech)"),
    DESTRON("FDX-A / Destron (animal)"),
    VIKING("Viking"),
    VISA2000("Visa2000"),
    NORALSY("Noralsy"),
    PRESCO("Presco"),
    FDXB_A0("FDX-B (Animal flag 0)"),
    FDXB_A1("FDX-B (Animal flag 1)"),
    RAWCLONE("Raw clone (paste blocks)")
}
