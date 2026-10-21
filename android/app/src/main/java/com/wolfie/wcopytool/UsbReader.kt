package com.wolfie.wcopytool

import android.hardware.usb.*

// USB-OTG transport + high-level LF operations. All calls are blocking and must run off the main
// thread. Synchronous request/reply over the HID interrupt endpoints (or control SET_REPORT).
class UsbReader(private val mgr: UsbManager) {
    private var conn: UsbDeviceConnection? = null
    private var intf: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    var device: UsbDevice? = null; private set
    val connected get() = conn != null && epIn != null

    fun findDevice(): UsbDevice? =
        mgr.deviceList.values.firstOrNull { d -> Proto.KNOWN.any { it.first == d.vendorId && it.second == d.productId } }
            ?: mgr.deviceList.values.firstOrNull { d -> (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_HID } }

    fun open(dev: UsbDevice): String {
        close()
        val hid = (0 until dev.interfaceCount).map { dev.getInterface(it) }
            .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_HID } ?: return "No HID interface"
        var inEp: UsbEndpoint? = null; var outEp: UsbEndpoint? = null
        for (i in 0 until hid.endpointCount) {
            val e = hid.getEndpoint(i)
            if (e.direction == UsbConstants.USB_DIR_IN) inEp = e else outEp = e
        }
        if (inEp == null) return "No IN endpoint on HID interface"
        val c = mgr.openDevice(dev) ?: return "openDevice failed (permission?)"
        if (!c.claimInterface(hid, true)) { c.close(); return "claimInterface failed" }
        conn = c; intf = hid; epIn = inEp; epOut = outEp; device = dev
        return "Connected ${"%04X".format(dev.vendorId)}:${"%04X".format(dev.productId)} (${if (outEp != null) "interrupt OUT" else "control SET_REPORT"})"
    }

    fun close() {
        try { intf?.let { conn?.releaseInterface(it) } } catch (_: Exception) {}
        try { conn?.close() } catch (_: Exception) {}
        conn = null; intf = null; epIn = null; epOut = null; device = null
    }

    private fun send(frame: ByteArray): Boolean {
        val c = conn ?: return false
        val out = epOut
        return if (out != null) c.bulkTransfer(out, frame, frame.size, 1000) >= 0
        else c.controlTransfer(0x21, 0x09, 0x0200, intf?.id ?: 0, frame, frame.size, 1000) >= 0
    }
    private fun recv(timeoutMs: Int = 600): ByteArray? {
        val c = conn ?: return null; val inp = epIn ?: return null
        val buf = ByteArray(Proto.REPORT_LEN)
        val n = c.bulkTransfer(inp, buf, buf.size, timeoutMs)
        return if (n > 0) buf.copyOf(n) else null
    }
    // One command → one reply.
    private fun transact(payload: IntArray, timeoutMs: Int = 600): Proto.Parsed? {
        if (!send(Proto.build(payload))) return null
        val r = recv(timeoutMs) ?: return null
        return Proto.parse(r)
    }
    private fun sendSeq(items: List<IntArray>, log: (String) -> Unit) {
        for (p in items) { transact(p, 400); Thread.sleep(90) }   // settle time for the T5577 to commit each write
    }

    // ---- key-variant expansion ----
    private fun eq(a: IntArray, b: IntArray) = a.contentEquals(b)
    fun expandKeys(keys: List<IntArray>, bitRev: Boolean, byteRev: Boolean): List<IntArray> {
        val out = ArrayList<IntArray>()
        fun add(k: IntArray) { if (out.none { eq(it, k) }) out.add(k) }
        for (k in keys) { add(k); if (bitRev) add(Proto.bitrev4(k)); if (byteRev) add(Proto.rev4(k)) }
        return out
    }

    // ---- read ----
    fun readEMId(freq: Long): Long? {
        transact(Proto.lfRFConfig(freq))
        for (i in 0 until 8) { Proto.recEMid(transact(Proto.lfRead(freq)))?.let { return it }; Thread.sleep(40) }
        return null
    }
    fun readHID(freq: Long): Proto.HidRead? {
        transact(Proto.lfRFConfig(freq))
        for (i in 0 until 8) { val r = Proto.hidDecode(transact(Proto.hidReadCmd())); if (r?.fmt != null) return r; Thread.sleep(40) }
        return null
    }

    // ---- unified T5577 write (data blocks + config block 0, with password handling) ----
    fun writeCard(dataBlocks: LongArray, baseConfig: Long, protect: Boolean, pwd: String, cur: String, freq: Long, log: (String) -> Unit) {
        val zero = intArrayOf(0, 0, 0, 0)
        val setPwd = if (protect) Proto.fieldKey(pwd) else zero
        val curK = Proto.fieldKey(cur)
        val cfg = Proto.u32be(baseConfig or (if (protect) 0x10L else 0L))
        val b7 = ArrayList<IntArray>(); fun addB(k: IntArray) { if (b7.none { eq(it, k) }) b7.add(k) }
        addB(curK); addB(zero); Proto.NORMALIZE.forEach { addB(Proto.keyBytes(it)) }
        val d = ArrayList<IntArray>(); fun addD(k: IntArray) { if (d.none { eq(it, k) }) d.add(k) }
        addD(setPwd); addD(curK); addD(zero)
        log("write ${dataBlocks.size} blocks, config ${Proto.hexJoin(cfg)}")
        val seq = ArrayList<IntArray>()
        seq.add(Proto.lfRFConfig(freq))
        for (c in b7) seq.add(Proto.lfT5Write(7, setPwd, c, freq))
        val blocks = ArrayList<Pair<Int, IntArray>>()
        dataBlocks.forEachIndexed { i, w -> blocks.add((i + 1) to Proto.u32be(w)) }
        blocks.add(0 to cfg)
        for ((blk, data) in blocks) { seq.add(Proto.lfT5WriteNoPwd(blk, data, freq)); for (pw in d) seq.add(Proto.lfT5Write(blk, data, pw, freq)) }
        seq.add(Proto.lfModeCmd(0x64, freq))
        sendSeq(seq, log)
        log("done")
    }

    // ---- EM4305 write (login-authenticated word writes) ----
    fun writeEM4305(id: Long, protect: Boolean, pwd: String, cur: String, freq: Long, log: (String) -> Unit) {
        val zero = intArrayOf(0, 0, 0, 0)
        val setPwd = if (protect) Proto.fieldKey(pwd) else zero
        val (w1, w2) = Proto.em4100Words(id)
        val cands = ArrayList<IntArray>()
        addDedup(cands, Proto.fieldKey(cur)); addDedup(cands, zero)
        log("EM4305 write id $id")
        val seq = ArrayList<IntArray>()
        for (c in cands) { seq.add(Proto.em4305Login(c, freq)); seq.add(Proto.em4305Write(2, setPwd, freq)) }
        seq.add(Proto.em4305Login(setPwd, freq))
        seq.add(Proto.em4305Write(5, Proto.u32be(w1), freq)); seq.add(Proto.em4305Write(6, Proto.u32be(w2), freq))
        seq.add(Proto.em4305Write(4, Proto.EM4305_CONFIG, freq))
        sendSeq(seq, log); log("done")
    }
    private fun addDedup(l: ArrayList<IntArray>, k: IntArray) { if (l.none { eq(it, k) }) l.add(k) }

    // ---- identifying EM4305 unlock ----
    fun unlockEM4305(keys: List<IntArray>, freq: Long, log: (String) -> Unit): String {
        val orig = readEMId(freq) ?: run { log("no card"); return "no card" }
        val marker = orig xor 1
        val (mw1, mw2) = Proto.em4100Words(marker)
        fun probe(k: IntArray) { transact(Proto.em4305Login(k, freq)); transact(Proto.em4305Write(5, Proto.u32be(mw1), freq)); transact(Proto.em4305Write(6, Proto.u32be(mw2), freq)); Thread.sleep(120) }
        probe(intArrayOf(0, 0, 0, 0))
        if (readEMId(freq) == marker) { restoreEM(orig, null, freq); log("card has no password (not protected)"); return "no password" }
        for ((i, k) in keys.withIndex()) {
            probe(k)
            if (readEMId(freq) == marker) { restoreEM(orig, k, freq); val ks = Proto.hexJoin(k); log("password is $ks"); return ks }
            if (i % 8 == 7) log("…tried ${i + 1}/${keys.size}")
        }
        log("not found in ${keys.size} keys"); return "not found"
    }
    private fun restoreEM(id: Long, foundKey: IntArray?, freq: Long) {
        val (w1, w2) = Proto.em4100Words(id)
        val seq = ArrayList<IntArray>()
        if (foundKey != null) { seq.add(Proto.em4305Login(foundKey, freq)); seq.add(Proto.em4305Write(2, intArrayOf(0, 0, 0, 0), freq)) }
        seq.add(Proto.em4305Login(intArrayOf(0, 0, 0, 0), freq))
        seq.add(Proto.em4305Write(5, Proto.u32be(w1), freq)); seq.add(Proto.em4305Write(6, Proto.u32be(w2), freq))
        seq.add(Proto.em4305Write(4, Proto.EM4305_CONFIG, freq)); seq.add(Proto.lfRead(freq))
        sendSeq(seq) {}
    }

    // ---- identifying T5577 unlock: find the key, restore id, clear protection ----
    fun unlockT5577(keys: List<IntArray>, freq: Long, log: (String) -> Unit): String {
        val orig = readEMId(freq) ?: run { log("no card"); return "no card" }
        val marker = orig xor 1
        val (mw1, mw2) = Proto.em4100Words(marker)
        val z = intArrayOf(0, 0, 0, 0)
        log("unlock: baseline id=%010X  probe-marker=%010X".format(orig, marker))
        // Precheck "already unprotected": write the marker authenticating with password 0 (op13) and read
        // it back; a marker readback means the card is open. KEY FACT from the logs: this device drops the
        // first several writes after a read/config ("cold"), and only starts committing after a handful
        // have gone out ("warm") — that is why the lone precheck write failed while the sweep, a few writes
        // later, saw the marker commit. So retry: each pass both warms the write path and self-tests. On an
        // open card the marker commits within a pass or two (confirmed with a second read to reject FFFF
        // glitches); on a protected card the auth-0 writes stay rejected every pass (block 7 enforces auth),
        // so it never commits and we fall through to the sweep. Only auth-0 writes are used, so a protected
        // card is never accidentally opened.
        transact(Proto.lfRFConfig(freq))
        var opened = false
        for (attempt in 0 until 4) {
            transact(Proto.lfT5Write(7, z, z, freq))   // warm-up; no-op on an open card, rejected on a protected one
            transact(Proto.lfT5Write(1, Proto.u32be(mw1), z, freq))
            transact(Proto.lfT5Write(2, Proto.u32be(mw2), z, freq))
            Thread.sleep(180)
            val r = readEMId(freq)
            if (attempt == 0 || r == marker) log("precheck pass${attempt + 1} readback=%010X".format(r ?: -1L))
            if (r == marker && readEMId(freq) == marker) { opened = true; break }
        }
        if (opened) { log("precheck: card is unprotected"); restoreT5(orig, z, freq, log); log("card has no password (not protected)"); return "no password" }
        log("precheck: protected — sweeping ${keys.size} key(s)")
        transact(Proto.lfT5Write(7, z, z, freq)); Thread.sleep(80)   // prime so the first key's write isn't the dropped one
        for ((i, k) in keys.withIndex()) {
            // Clear block 7 with the candidate, then write the marker with password 0 — only the real
            // password lets block 7 clear, so only then does the pwd-0 marker write take.
            transact(Proto.lfT5Write(7, z, k, freq))
            transact(Proto.lfT5Write(1, Proto.u32be(mw1), z, freq))
            transact(Proto.lfT5Write(2, Proto.u32be(mw2), z, freq))
            Thread.sleep(200)
            val rb = readEMId(freq)
            if (i < 4) log("key ${Proto.hexJoin(k)} -> readback=%010X".format(rb ?: -1L))
            // Confirm a hit with a second read — this hardware occasionally glitches a readback.
            if (rb == marker && readEMId(freq) == marker) { val ks = Proto.hexJoin(k); log("password is $ks — clearing protection"); restoreT5(orig, k, freq, log); return ks }
            if (i % 8 == 7) log("…tried ${i + 1}/${keys.size}")
        }
        log("not found in ${keys.size} keys"); return "not found"
    }
    // Leave the card UNPROTECTED. After the sweep, block 7 is 0 (cleared with the found key) but the PWD
    // bit in block 0 is still set, so the card is "protected with password 0". Clear the PWD bit by writing
    // block 0 = 00148040 authenticated with password 0 (op13), with generous settle time, then VERIFY the
    // card really ended unprotected and log the result so the failing step is unambiguous.
    private fun restoreT5(id: Long, foundKey: IntArray, freq: Long, log: (String) -> Unit) {
        val (w1, w2) = Proto.em4100Words(id)
        val z = intArrayOf(0, 0, 0, 0)
        val open = Proto.u32be(0x00148040L)
        transact(Proto.lfT5Write(7, z, z, freq)); Thread.sleep(150)      // block 7 = 0 (auth 0)
        transact(Proto.lfT5Write(0, open, z, freq)); Thread.sleep(260)   // block 0 = 00148040 (auth 0) clears PWD bit
        transact(Proto.lfT5WriteNoPwd(0, open, freq)); Thread.sleep(150) // reassert config (op12)
        // Verify: a marker write authenticated with password 0 commits only if the card is now open.
        val marker = id xor 1
        val (mk1, mk2) = Proto.em4100Words(marker)
        transact(Proto.lfT5Write(1, Proto.u32be(mk1), z, freq))
        transact(Proto.lfT5Write(2, Proto.u32be(mk2), z, freq))
        Thread.sleep(200)
        val chk = readEMId(freq)
        if (chk == marker) log("restore verify: UNPROTECTED ok (readback=%010X)".format(chk))
        else log("restore verify: STILL PROTECTED (readback=%010X want %010X)".format(chk ?: -1L, marker))
        // Write the real id back (auth 0).
        transact(Proto.lfT5Write(1, Proto.u32be(w1), z, freq)); transact(Proto.lfT5WriteNoPwd(1, Proto.u32be(w1), freq))
        transact(Proto.lfT5Write(2, Proto.u32be(w2), z, freq)); transact(Proto.lfT5WriteNoPwd(2, Proto.u32be(w2), freq))
        transact(Proto.lfModeCmd(0x05, freq)); Thread.sleep(100)
        log("restore: rewrote id=%010X".format(id))
    }

    // ---- HID unlock → convert to plain EM4100, identifying the password ----
    fun unlockHID(keys: List<IntArray>, emId: Long, freq: Long, log: (String) -> Unit): String {
        transact(Proto.lfRFConfig(freq))
        readEMId(freq)?.let { log("already plain EM id %010X".format(it)); return "not locked" }
        val marker = if (emId == 0L) 1L else emId xor 1
        val (mw1, mw2) = Proto.em4100Words(marker)
        val open = Proto.u32be(0x00148040L)
        for ((i, k) in keys.withIndex()) {
            val seq = listOf(
                Proto.lfT5Write(7, intArrayOf(0,0,0,0), k, freq),
                Proto.lfT5WriteNoPwd(1, Proto.u32be(mw1), freq), Proto.lfT5Write(1, Proto.u32be(mw1), intArrayOf(0,0,0,0), freq),
                Proto.lfT5WriteNoPwd(2, Proto.u32be(mw2), freq), Proto.lfT5Write(2, Proto.u32be(mw2), intArrayOf(0,0,0,0), freq),
                Proto.lfT5WriteNoPwd(0, open, freq), Proto.lfT5Write(0, open, intArrayOf(0,0,0,0), freq),
                Proto.lfModeCmd(0x05, freq)
            )
            sendSeq(seq) {}
            Thread.sleep(120)
            if (readEMId(freq) == marker) {
                val real = if (emId == 0L) 1L else emId
                restoreT5(real, intArrayOf(0, 0, 0, 0), freq, log)
                val ks = Proto.hexJoin(k)
                log("password was $ks; converted to plain EM4100 id %010X".format(real)); return ks
            }
            if (i % 8 == 7) log("…tried ${i + 1}/${keys.size}")
        }
        log("no known key cleared it"); return "not found"
    }
}
