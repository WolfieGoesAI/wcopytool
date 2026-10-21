import Cocoa

// Monospaced font with a Mojave (10.14) fallback — monospacedSystemFont is 10.15+.
func mono(_ size: CGFloat) -> NSFont {
    if #available(macOS 10.15, *) { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
    return NSFont(name: "Menlo", size: size) ?? NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size)
}

/// Top-left origin container so scrolled page content starts at the top.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// NSButton that calls a closure.
final class ActionButton: NSButton {
    var onClick: (() -> Void)?
    convenience init(_ title: String, _ action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: #selector(fire))
        self.target = self; self.onClick = action
        self.bezelStyle = .rounded
        self.controlSize = .regular
    }
    @objc private func fire() { onClick?() }
}

enum RecPhase { case idle, baseline, probe }

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {

    let hid = HIDTransport()
    var window: NSWindow!

    // shared top/bottom
    let statusField = NSTextField(labelWithString: "Not connected")
    let fStatus = NSTextField(labelWithString: "—"); let fLen = NSTextField(labelWithString: "—")
    let fUID = NSTextField(labelWithString: "—")
    let fPayload = NSTextField(labelWithString: "—"); let fAscii = NSTextField(labelWithString: "—")
    let respRaw = NSTextView()
    var logView: NSTextView!

    // page input fields
    let mfKey = NSTextField(string: "FFFFFFFFFFFF")
    var mfUseB = false
    let mfBlock = NSTextField(string: "0")
    let mfData = NSTextField(string: "00112233445566778899AABBCCDDEEFF")
    var sizeS70 = false
    let ntagPage = NSTextField(string: "4")
    let ntagData = NSTextField(string: "00000000")
    let idFreq = NSTextField(string: "125000")
    let lfWriteId = NSTextField(string: "1234567890")
    let lfPwd = NSTextField(string: "00000000")
    let lfProtect = NSButton(checkboxWithTitle: "Password-protect written card", target: nil, action: nil)
    let lfT5Found = NSTextField(string: "00000000")   // editable: found or user-entered password
    let lfEMFound = NSTextField(string: "00000000")
    let rawPayload = NSTextField(string: "FF 00 9A 5A A5 54 69 61 6E")
    let rawFrame = NSTextField(string: "01 0F 00 00 FF 00 9A 5A A5 54 69 61 6E")
    var regFields: [UInt8: NSTextField] = [:]

    // MARK: lifecycle
    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow(); wireHID()
        if !hid.start() { log("Could not start HID manager.") }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { hid.stop() }

    // MARK: layout helpers
    func hstack(_ v: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: v); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
    }
    func vstack(_ v: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: v); s.orientation = .vertical; s.alignment = .leading; s.spacing = spacing; return s
    }
    func head(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = NSFont.boldSystemFont(ofSize: 12); t.textColor = .secondaryLabelColor; return t
    }
    func field(_ f: NSTextField, _ w: CGFloat) -> NSTextField {
        f.font = mono(11); f.widthAnchor.constraint(equalToConstant: w).isActive = true; f.delegate = self; return f
    }
    func labeled(_ s: String, _ v: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: s); l.font = NSFont.systemFont(ofSize: 11)
        return hstack([l, v], spacing: 6)
    }

    // MARK: window
    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 720)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "wCopyTool — nfcPro / wCopy console"
        window.center()
        let content = NSView(frame: rect); window.contentView = content

        statusField.textColor = .systemRed
        let rescan = ActionButton("Rescan") { [weak self] in self?.rescan() }
        let topBar = hstack([statusField, NSView(), rescan])
        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topBar)

        // tabs
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, view) in [
            ("Card (13.56)", pageCard()),
            ("Sectors (Mifare)", pageSectors()),
            ("NTAG", pageNTAG()),
            ("125 kHz ID", pageID()),
            ("Config (RC522)", pageConfig()),
            ("Advanced", pageAdvanced()),
            ("Raw", pageRaw()),
        ] {
            let item = NSTabViewItem(identifier: title); item.label = title; item.view = wrapScroll(view); tabs.addTabViewItem(item)
        }
        content.addSubview(tabs)

        // shared response fields
        func fv(_ f: NSTextField) -> NSTextField { f.font = mono(11); f.isSelectable = true; return f }
        func pair(_ name: String, _ f: NSTextField) -> NSStackView {
            let l = NSTextField(labelWithString: name); l.font = NSFont.boldSystemFont(ofSize: 11); l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 58).isActive = true
            return hstack([l, fv(f)], spacing: 6)
        }
        let fieldsRow1 = hstack([pair("Status", fStatus), pair("Len", fLen), pair("UID", fUID)])
        let fieldsRow2 = hstack([pair("Data", fPayload)])
        let fieldsRow3 = hstack([pair("ASCII", fAscii)])
        let fieldsBox = vstack([head("Parsed response"), fieldsRow1, fieldsRow2, fieldsRow3], spacing: 6)
        fieldsBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fieldsBox)

        let respScroll = makeTextScroll(respRaw, mono(11))
        content.addSubview(respScroll)

        logView = NSTextView()
        let logScroll = makeTextScroll(logView, mono(10))
        content.addSubview(logScroll)

        let g = content
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: g.topAnchor, constant: 10),
            topBar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),

            tabs.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            tabs.heightAnchor.constraint(equalToConstant: 310),

            fieldsBox.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            fieldsBox.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14),
            fieldsBox.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),

            respScroll.topAnchor.constraint(equalTo: fieldsBox.bottomAnchor, constant: 8),
            respScroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            respScroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            respScroll.heightAnchor.constraint(equalToConstant: 120),

            logScroll.topAnchor.constraint(equalTo: respScroll.bottomAnchor, constant: 8),
            logScroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            logScroll.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    /// Build a correctly-configured scrollable NSTextView. A programmatic NSTextView must have
    /// its container/sizing set up or its text lays out at zero width and never shows.
    func makeTextScroll(_ tv: NSTextView, _ font: NSFont) -> NSScrollView {
        let sc = NSScrollView()
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.autohidesScrollers = false
        let big = CGFloat.greatestFiniteMagnitude
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: big, height: big)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = true
        tv.font = font
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 100, height: big)
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        sc.documentView = tv
        return sc
    }

    func wrapScroll(_ v: NSView) -> NSView {
        let sv = NSScrollView(); sv.hasVerticalScroller = true; sv.drawsBackground = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: doc.topAnchor, constant: 10),
            v.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -10),
            v.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -10),
        ])
        sv.documentView = doc
        doc.widthAnchor.constraint(equalTo: sv.widthAnchor).isActive = true
        return sv
    }

    // MARK: pages

    func pageCard() -> NSView {
        func b(_ t: String, _ op: UInt8) -> ActionButton { ActionButton(t) { [weak self] in self?.tx(op) } }
        let g1 = hstack([
            ActionButton("Init / Unlock") { [weak self] in self?.sendPayload([0xFF,0x00,0x9A,0x5A,0xA5,0x54,0x69,0x61,0x6E], "Init handshake") },
            b("Detect (0x12)", 0x12), b("Read number (0x13)", 0x13), b("Get version (0x1F)", 0x1F),
        ])
        let g2 = hstack([ b("One-click decode (0x32)", 0x32), b("Status/select (0x47)", 0x47), b("Data exchange (0x40)", 0x40) ])
        let g3 = hstack([ b("Write MF1 (0x41)", 0x41), b("Write CUID/FUID (0x42)", 0x42), b("Write GTU (0x43)", 0x43), b("Write GDM (0x44)", 0x44) ])
        let g4 = hstack([ b("Lock / paged (0x46)", 0x46), b("Key helper (0x3F)", 0x3F), b("Key helper (0x4F)", 0x4F) ])
        let note = NSTextField(wrappingLabelWithString: "Opcodes shown in each label are confirmed; the action names are the best match to the Windows buttons — confirm the exact behaviour per unit. Results appear in the shared panel below.")
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 900
        return vstack([head("13.56 MHz card — detect / read / write"), g1, g2, g3, g4, note])
    }

    func pageSectors() -> NSView {
        let aRadio = NSButton(radioButtonWithTitle: "Key A", target: self, action: #selector(keyChanged(_:)))
        let bRadio = NSButton(radioButtonWithTitle: "Key B", target: self, action: #selector(keyChanged(_:)))
        aRadio.tag = 0; bRadio.tag = 1; aRadio.state = .on
        let s50 = NSButton(radioButtonWithTitle: "S50 (16 sec)", target: self, action: #selector(sizeChanged(_:)))
        let s70 = NSButton(radioButtonWithTitle: "S70 (40 sec)", target: self, action: #selector(sizeChanged(_:)))
        s50.tag = 0; s70.tag = 1; s50.state = .on
        let row1 = hstack([labeled("Key:", field(mfKey, 160)), aRadio, bRadio, s50, s70])
        let row2 = hstack([labeled("Block:", field(mfBlock, 60)),
                           ActionButton("Auth (0x34)") { [weak self] in self?.mfAuth() },
                           ActionButton("Read block (0x32)") { [weak self] in self?.mfRead() }])
        let row3 = hstack([labeled("Data (16B hex):", field(mfData, 320)),
                           ActionButton("Write block (0x33)") { [weak self] in self?.mfWrite() }])
        let row4 = hstack([ActionButton("Read sector 0") { [weak self] in self?.mfReadSector0() },
                           ActionButton("Dump all blocks") { [weak self] in self?.mfDumpAll() }])
        let note = NSTextField(wrappingLabelWithString: "Experimental frame layout: FF 00 66 00 1E <A=125000> <OP> <block u32> [+ keytype+key for Auth, +16 data for Write]. Watch the reply and adjust.")
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor; note.preferredMaxLayoutWidth = 900
        return vstack([head("Mifare Classic — sectors / blocks"), row1, row2, row3, row4, note])
    }

    func pageNTAG() -> NSView {
        let row1 = hstack([labeled("Page:", field(ntagPage, 60)),
                           ActionButton("Read page (0x42)") { [weak self] in self?.ntagRead() },
                           ActionButton("Get version (0x1F)") { [weak self] in self?.tx(0x1F) }])
        let row2 = hstack([labeled("Data (4B hex):", field(ntagData, 120)),
                           ActionButton("Write page (0x33)") { [weak self] in self?.ntagWrite() }])
        let row3 = hstack([ActionButton("Read all pages") { [weak self] in self?.ntagReadAll() },
                           ActionButton("CFG0 (0x85/12)") { [weak self] in self?.sendPayload([0xFF,0x00,0x85,0x12], "RC522/NTAG cfg 0x12") },
                           ActionButton("CFG1 (0x85/32)") { [weak self] in self?.sendPayload([0xFF,0x00,0x85,0x32], "RC522/NTAG cfg 0x32") }])
        return vstack([head("NTAG 21x — pages"), row1, row2, row3])
    }

    func pageID() -> NSView {
        let dev = hstack([
            ActionButton("Device info (0x68)") { [weak self] in self?.sendPayload([0xFF,0x00,0x68], "device info") },
            ActionButton("Serial number (0x69)") { [weak self] in self?.sendPayload([0xFF,0x00,0x69], "serial") },
        ])
        // Confirmed LF read: FF 00 65 05 1E <freq> 00 00 00 00 → reply 02 0C 01 00 05 <5-byte EM id> CHK FD
        // Frequency is fixed at 125 kHz — every LF command in the original app uses it, and EM4100 /
        // T5577 are 125 kHz chips. (idFreq stays at 125000 internally.)
        let readRow = hstack([ActionButton("Read ID (EM4100)") { [weak self] in
                                  guard let s = self else { return }
                                  s.sendPayload(lfRead(freq: parseU32(s.idFreq.stringValue)), "LF read EM4100") }])
        // Write — rewrites all LF chip types (T5577 + EM4305) the way the original app does.
        let writeRow = hstack([labeled("Card #:", field(lfWriteId, 130)),
                               ActionButton("Write T5577") { [weak self] in self?.writeEM(false) },
                               ActionButton("Write EM4305") { [weak self] in self?.writeEM(true) },
                               ActionButton("Write all LF") { [weak self] in guard let s = self else { return }
                                   s.writeLFAll(id: parseU40(s.lfWriteId.stringValue)) },
                               ActionButton("Revive") { [weak self] in self?.reviveT5() }])
        // Protection for the written card: unchecked = no password; checked = set the password below
        // (blank = 00000000). The written card's config PWD bit follows this checkbox.
        let protectRow = hstack([lfProtect, labeled("Write Lock Password:", field(lfPwd, 100))])
        // EM4305 read-only recovery (only works on a read-protected EM4305; a readable card's write
        // password can't be read-recovered — use Unlock for that).
        let findRow = hstack([NSTextField(labelWithString: "Read-protected EM4305:"),
                              ActionButton("Find EM4305 pwd (read)") { [weak self] in self?.findPwd(true) }])
        // Unlock finds the card's current password (tries known keys + the password fields), clears
        // it, and writes the found password into the Unlock Password field.
        let foundRow = hstack([
            labeled("T5577 Unlock Password:", field(lfT5Found, 100)),
            ActionButton("Unlock T5577") { [weak self] in self?.unlockCard(false) },
            labeled("EM4305 Unlock Password:", field(lfEMFound, 100)),
            ActionButton("Unlock EM4305") { [weak self] in self?.unlockCard(true) }])
        let warn = NSTextField(wrappingLabelWithString: "⚠︎ Write authenticates with the card\u{2019}s CURRENT password — the \u{201C}Unlock Password\u{201D} field for that chip (leave blank for an unprotected card); if it\u{2019}s wrong the write is simply rejected. Tick \u{201C}Password-protect\u{201D} to lock the written card with the Write Lock Password (blank = 00000000, config 00148050); leave it unticked to write unprotected (config 00148040). Unlock finds the password by trying every known key plus the two password fields, clears it, and fills the found value into the Unlock Password field.")
        warn.font = NSFont.systemFont(ofSize: 10); warn.textColor = .systemOrange; warn.preferredMaxLayoutWidth = 900
        return vstack([head("125 kHz ID"), dev, readRow, writeRow, protectRow, foundRow, findRow, warn])
    }

    // Send a timed sequence so the reader isn't overrun; replies arrive via the input callback.
    func sendSeq(_ items: [([UInt8], String)], gap: Double = 0.25) {
        for (i, item) in items.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(i)) { [weak self] in
                self?.sendPayload(item.0, item.1)
            }
        }
    }

    // EM4100 data write to a chip (T5577 op 0x13 / EM4305 op 0x12): data to addr 1,2,
    // config to addr 0, then read back to verify. Uses the Password field for protected cards.
    func currentPwd() -> [UInt8] { keyBytes(lfPwd.stringValue) }
    // Set when a write is in flight: the id we wrote and the chip, so the verify read can confirm
    // the chip actually accepted the write (vs. the device acking while a protected chip ignores it).
    var writeExpectId: UInt64? = nil
    var writeExpectEM = false
    // Entry points: "Write T5577" and "Write EM4305" buttons. Both write the given chip's full
    // sequence. The original app writes BOTH in one pass (so a copy works whatever the chip is);
    // "Write all LF" / Revive does that.
    func writeEM(_ em4305: Bool) {
        let id = parseU40(lfWriteId.stringValue)
        writeExpectId = id; writeExpectEM = em4305
        var seq = [(lfRFConfig(freq: parseU32(idFreq.stringValue)), "RF config"),
                   (lfModeCmd(0x14, freq: parseU32(idFreq.stringValue)), "LF begin")]
        seq += (em4305 ? em4305Seq(id: id) : t5577Seq(id: id))
        seq += finishLFSeq()
        log("\(em4305 ? "EM4305" : "T5577") write id=\(String(format: "%010llX", id)) — \(seq.count) frames (op12+op13, password normalised)")
        sendSeq(seq, gap: 0.3)
    }
    // Write every LF chip type in one pass (T5577 + EM4305), exactly as the original app does.
    func writeLFAll(id: UInt64) {
        writeExpectId = id; writeExpectEM = false
        let freq = parseU32(idFreq.stringValue)
        var seq = [(lfRFConfig(freq: freq), "RF config"), (lfModeCmd(0x14, freq: freq), "LF begin")]
        seq += t5577Seq(id: id)
        seq += em4305Seq(id: id)
        seq += finishLFSeq()
        log("Write all LF types id=\(String(format: "%010llX", id)) — T5577 + EM4305, \(seq.count) frames")
        sendSeq(seq, gap: 0.28)
    }
    func finishLFSeq() -> [([UInt8], String)] {
        let freq = parseU32(idFreq.stringValue)
        return [(lfModeCmd(0x05, freq: freq), "LF read-mode"), (lfRead(freq: freq), "verify read")]
    }

    // The password to SET on the written card. Unchecked = unprotected (00000000). Checked = the
    // Password field (blank counts as 00000000). We never set "Tian" — it is only tried as a
    // CURRENT password to authenticate a card the original app previously locked.
    func protectOn() -> Bool { lfProtect.state == .on }
    // The NEW password to set: the Password field when the checkbox is ticked (blank = 00000000);
    // otherwise 00000000 (card left unprotected).
    func targetPwd() -> [UInt8] { protectOn() ? fieldKey(lfPwd.stringValue) : [0,0,0,0] }
    // Parse a text field as a 4-byte key only when it is exactly 8 hex digits; otherwise 0 (so
    // status text like "swept — now pwd 0" is treated as no password, not garbage).
    func fieldKey(_ s: String) -> [UInt8] {
        let h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        return (h.count == 8 && h.allSatisfy { $0.isHexDigit }) ? keyBytes(h) : [0,0,0,0]
    }

    // T5577 write. Authenticates ONLY with the current password in the "T5577 pwd" field (empty =
    // unprotected). Sets the new password to the "Password" field when the protect checkbox is
    // ticked, else leaves the card unprotected. No key sweep — to clear an unknown password, use
    // Unlock T5577 first. If the auth password is wrong the writes are rejected and the card is
    // unchanged.
    func t5577Seq(id: UInt64) -> [([UInt8], String)] {
        let freq = parseU32(idFreq.stringValue)
        let (w1, w2) = em4100Words(id)
        let authPwd = fieldKey(lfT5Found.stringValue)   // current password (to write a protected card)
        let setPwd = targetPwd()                         // new password to set
        let cfg: [UInt8] = protectOn() ? [0x00,0x14,0x80,0x50] : [0x00,0x14,0x80,0x40]
        var seq: [([UInt8], String)] = []
        // Change the password first (block 7), authenticating with the current password.
        seq.append((lfT5Write(addr: 7, word: setPwd, pwd: authPwd, freq: freq), "block7 = new pwd (auth \(hex(authPwd)))"))
        // Then write data + config, authenticating with the (now) new password.
        for (blk, data, name) in [(UInt8(1), u32be(w1), "block1"), (2, u32be(w2), "block2"), (0, cfg, "block0 cfg")] {
            seq.append((lfT5WriteNoPwd(addr: blk, word: data, freq: freq), "\(name) op12"))
            seq.append((lfT5Write(addr: blk, word: data, pwd: setPwd, freq: freq), "\(name) op13"))
        }
        return seq
    }
    // EM4305 write. Authenticates with the "EM4305 pwd" field (empty = unprotected), sets the new
    // password from the Password field when the checkbox is ticked, else leaves it unprotected.
    func em4305Seq(id: UInt64) -> [([UInt8], String)] {
        let freq = parseU32(idFreq.stringValue)
        let (w1, w2) = em4100Words(id)
        let authPwd = fieldKey(lfEMFound.stringValue)
        let setPwd = targetPwd()
        var seq: [([UInt8], String)] = []
        seq.append((em4305LoginBytes(pwd: authPwd, freq: freq), "login (current \(hex(authPwd)))"))
        seq.append((em4305WriteWord(addr: 2, bytes: setPwd, freq: freq), "word2 = new pwd"))
        seq.append((em4305LoginBytes(pwd: setPwd, freq: freq), "login (new pwd)"))
        seq.append((em4305WriteWord(addr: 5, bytes: u32be(w1), freq: freq), "word5 data1"))
        seq.append((em4305WriteWord(addr: 6, bytes: u32be(w2), freq: freq), "word6 data2"))
        seq.append((em4305WriteWord(addr: 4, bytes: kEM4305ConfigWire, freq: freq), "word4 cfg"))
        return seq
    }

    // Revive: read whatever id the card still broadcasts (it reads even when write-protected); if it
    // is truly silent, fall back to the Card# field. Then rewrite every LF type to bring it back.
    func reviveT5() {
        guard recPhase == .idle, !unlockActive, !reviveActive else { log("busy"); return }
        reviveActive = true; reviveReadRetries = 0
        log("Revive: reading current id (falls back to the Card # field if the card is silent)…")
        sendPayload(lfRead(freq: parseU32(idFreq.stringValue)), "revive: read id")
    }
    var reviveActive = false
    var reviveReadRetries = 0
    func handleRevive(_ bytes: [UInt8]) {
        if let id = recEMid(bytes) {
            reviveActive = false
            lfWriteId.stringValue = String(id)
            log(String(format: "Revive: card reads id=%010llX — rewriting all LF types.", id))
            writeLFAll(id: id)
        } else if reviveReadRetries < 5 {
            reviveReadRetries += 1
            sendPayload(lfRead(freq: parseU32(idFreq.stringValue)), "revive: re-read id")
        } else {
            reviveActive = false
            let id = parseU40(lfWriteId.stringValue)
            if id != 0 {
                log("Revive: card is silent — rewriting the id from the Card # field.")
                writeLFAll(id: id)
            } else {
                log("Revive: card is silent and Card # is empty. Type the target id into Card # and press Revive again.")
            }
        }
    }

    // ---- Write-test password recovery (state machine) ----
    // READ-ONLY password search — it never writes a block, so it can NEVER brick the card
    // (important: newer T5577s have no test mode, so there is no after-the-fact unbrick).
    //   T5577  — password-read: 0x65 read with the candidate in the password field (lfReadPwd).
    //   EM4305 — login (op 0x21, authenticate only) then read.
    // A hit is a candidate that yields a stable, valid EM id when the no-password read did not.
    // If the card reads fine WITHOUT a password it is not read-protected, so its write-password
    // cannot be observed by reading — we stop and say so rather than fall back to writes.
    var recPhase: RecPhase = .idle
    var recEM = false
    var recCands: [(String,[UInt8])] = []
    var recIdx = 0
    var recFreq: UInt32 = 125000
    var recSamples: [UInt64] = []    // valid ids seen during the no-password baseline
    var recAttempts = 0              // total baseline reads attempted
    var recProbe: [UInt64?] = []     // reads collected for the current candidate
    var recEvaluate = true           // false while an EM4305 login is in flight (ignore its reply)
    let recReadGap = 0.12            // gentle spacing between reads
    let recBaselineCount = 4         // no-password reads used to decide read-protection
    let recProbeCount = 2            // reads per candidate; a hit must be valid & equal on all

    func afterDelay(_ d: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }

    func findPwd(_ em4305: Bool) {
        guard recPhase == .idle, !unlockActive else { log("busy — another operation is running"); return }
        recEM = em4305; recFreq = parseU32(idFreq.stringValue)
        recCands = kLFKeyDict.flatMap { k in keyForms(k).map { (k + $0.0, $0.1) } }
        recIdx = 0; recSamples = []; recAttempts = 0; recEvaluate = true
        recPhase = .baseline
        (em4305 ? lfEMFound : lfT5Found).stringValue = "testing…"
        log("Find \(em4305 ? "EM4305" : "T5577") password (read-only — no writes): checking whether the card reads without a password…")
        sendPayload(lfRead(freq: recFreq), "baseline read")
    }
    func recEMid(_ bytes: [UInt8]) -> UInt64? {
        guard let (p, _, _, _) = Frame.parse(bytes), p.count == 6, p[0] == 0x05 else { return nil }
        return p[1...5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    // Send one read sample for a candidate. T5577: a password-read. EM4305: login (auth only)
    // then read — the login reply is ignored (recEvaluate=false) so only the read counts.
    // Neither path writes any block.
    func recSendSample(_ key: [UInt8], _ label: String) {
        if recEM {
            recEvaluate = false
            sendPayload(em4305LoginBytes(pwd: key, freq: recFreq), "login \(label)")
            afterDelay(recReadGap) { [weak self] in guard let s = self else { return }
                s.recEvaluate = true
                s.sendPayload(lfRead(freq: s.recFreq), "probe \(label)") }
        } else {
            recEvaluate = true
            sendPayload(lfReadPwd(pwd: key, freq: recFreq), "probe \(label)")
        }
    }
    func tryRecCandidate() {
        guard recIdx < recCands.count else {
            log("✗ password not found in the dictionary (\(recCands.count) tried). The card was only read, never written — it is unchanged.")
            (recEM ? lfEMFound : lfT5Found).stringValue = "not found"
            recPhase = .idle; return
        }
        recProbe = []
        let (label, key) = recCands[recIdx]
        recSendSample(key, label)
    }
    func handleRecovery(_ bytes: [UInt8]) {
        if !recEvaluate { return }               // ignore an EM4305 login reply; wait for the read
        let emid = recEMid(bytes)
        switch recPhase {
        case .baseline:
            recAttempts += 1
            if let id = emid { recSamples.append(id) }
            if recAttempts < recBaselineCount {
                afterDelay(recReadGap) { [weak self] in guard let s = self else { return }
                    s.sendPayload(lfRead(freq: s.recFreq), "baseline read") }
                return
            }
            if recSamples.count * 2 >= recBaselineCount {   // reads fine without a password
                let id = recSamples.first ?? 0
                log(String(format: "Card reads without a password (id=%010llX) — it is write-protected only, not read-protected.", id))
                log("  A write-protected card's password can't be identified by reading. But these cards use a known password set (the app's default is \u{201C}Tian\u{201D}), so press Unlock \(recEM ? "EM4305" : "T5577") to clear it — that safely tries every known key and rewrites the same id. \u{201C}Tian\u{201D} is pre-filled below as the most likely one.")
                (recEM ? lfEMFound : lfT5Found).stringValue = "5469616E"
                recPhase = .idle
            } else {                                         // silent without a password → read-protected
                log("Card does not read without a password → read-protected. Sweeping \(recCands.count) candidates by \(recEM ? "login" : "password-read") (read-only)…")
                recIdx = 0; recPhase = .probe
                tryRecCandidate()
            }
        case .probe:
            recProbe.append(emid)
            let (label, key) = recCands[recIdx]
            if recProbe.count < recProbeCount {
                afterDelay(recReadGap) { [weak self] in self?.recSendSample(key, label) }
                return
            }
            let ids = recProbe.compactMap { $0 }
            if ids.count == recProbe.count, let first = ids.first, ids.allSatisfy({ $0 == first }) {
                recPhase = .idle                             // stable valid id on every read → hit
                (recEM ? lfEMFound : lfT5Found).stringValue = key.map { String(format: "%02X", $0) }.joined()
                log(String(format: "✓ PASSWORD FOUND: %@ (wire %@) — card now reads id=%010llX. No writes were made.",
                           label, hex(key), first))
            } else {
                recIdx += 1
                afterDelay(recReadGap) { [weak self] in self?.tryRecCandidate() }
            }
        case .idle:
            break
        }
    }
    // ---- Unlock: read current id, rewrite it with the found/entered password, and reset the
    // password to 0 with protection cleared, leaving the card writable without a password.
    var unlockActive = false
    var unlockEM = false
    var unlockReadRetries = 0
    // Every known password, wire-byte form, most-likely first. These are the passwords the original
    // app and this ecosystem use, so an ecosystem card's password is almost always in here.
    func allKnownKeys() -> [[UInt8]] {
        var out: [[UInt8]] = []
        func add(_ b: [UInt8]) { if !out.contains(where: { $0 == b }) { out.append(b) } }
        let typed = fieldKey((unlockEM ? lfEMFound : lfT5Found).stringValue)   // the Unlock Password field
        if typed != [0,0,0,0] { add(typed) }
        let wlp = fieldKey(lfPwd.stringValue)           // also try the Write Lock Password field
        if wlp != [0,0,0,0] { add(wlp) }
        add(keyBytes("5469616E"))                       // "Tian" — the app's default, by far the most common
        for k in kT5NormalizeKeys { add(keyBytes(k)) }
        for k in kLFKeyDict { add(keyBytes(k)) }
        return out
    }
    func unlockCard(_ em4305: Bool) {
        guard recPhase == .idle, !unlockActive, !reviveActive, !ulActive else { log("busy — another operation is running"); return }
        if em4305 {
            unlockEM = true; unlockActive = true; unlockReadRetries = 0
            log("Unlock EM4305: reading id, then clearing the password by trying every known key…")
            sendPayload(lfRead(freq: parseU32(idFreq.stringValue)), "read id")
        } else {
            startUnlockT5()
        }
    }

    // ---- Identifying T5577 unlock: find WHICH known key unlocks, stop at it, populate the field ----
    // Per key K: zero the password block authenticating with K, then write a MARKER id with password 0.
    // Only the correct key clears the password, so only then does the marker take and the read change.
    // On a hit we restore the real id and clear the PWD bit; the found key is written to the pwd field.
    enum ULPhase { case idle, baseline, test }
    var ulActive = false
    var ulPhase: ULPhase = .idle
    var ulKeys: [[UInt8]] = []
    var ulIdx = 0
    var ulOrigId: UInt64 = 0
    var ulMarker: UInt64 = 0
    var ulFreq: UInt32 = 125000
    var ulQueue: [([UInt8], String)] = []
    var ulAwaitRead = false
    var ulReadRetries = 0
    let ulGap = 0.08
    let ulSettle = 0.2
    func hexJoin(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
    func startUnlockT5() {
        ulActive = true; ulPhase = .baseline; ulIdx = 0; ulReadRetries = 0; ulAwaitRead = false
        ulFreq = parseU32(idFreq.stringValue)
        unlockEM = false
        ulKeys = allKnownKeys()
        lfT5Found.stringValue = "unlocking…"
        log("Unlock T5577: testing \(ulKeys.count) known keys, stopping at the one that works…")
        sendPayload(lfRFConfig(freq: ulFreq), "RF config")      // gated: its reply triggers the baseline read
    }
    func ulStep() {
        if !ulQueue.isEmpty { let c = ulQueue.removeFirst(); afterDelay(ulGap) { [weak self] in self?.sendPayload(c.0, c.1) } }
        else { ulAwaitRead = true; ulReadRetries = 0; afterDelay(ulSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.ulFreq), "probe read") } }
    }
    func ulNextKey() {
        guard ulIdx < ulKeys.count else {
            ulActive = false; ulPhase = .idle
            lfT5Found.stringValue = "not found"
            log("✗ Unlock T5577: none of \(ulKeys.count) known keys unlocked the card — its password isn't in the known set.")
            return
        }
        let k = ulKeys[ulIdx]
        let (mw1, mw2) = em4100Words(ulMarker)
        ulQueue = [
            (lfT5Write(addr: 7, word: [0,0,0,0], pwd: k, freq: ulFreq), "clear pwd auth \(hexJoin(k))"),
            (lfT5Write(addr: 1, word: u32be(mw1), pwd: [0,0,0,0], freq: ulFreq), "probe blk1"),
            (lfT5Write(addr: 2, word: u32be(mw2), pwd: [0,0,0,0], freq: ulFreq), "probe blk2"),
        ]
        ulAwaitRead = false
        ulStep()
    }
    func ulKeyFound() {
        let k = ulKeys[ulIdx]
        ulActive = false; ulPhase = .idle
        lfT5Found.stringValue = hexJoin(k)                      // <-- found password populates the field
        log("✓ Unlock T5577: password is \(hexJoin(k)). Restoring id \(String(format: "%010llX", ulOrigId)) and clearing protection.")
        let (w1, w2) = em4100Words(ulOrigId)
        writeExpectId = ulOrigId; writeExpectEM = false
        sendSeq([
            (lfT5Write(addr: 1, word: u32be(w1), pwd: [0,0,0,0], freq: ulFreq), "restore blk1"),
            (lfT5Write(addr: 2, word: u32be(w2), pwd: [0,0,0,0], freq: ulFreq), "restore blk2"),
            (lfT5Write(addr: 0, word: [0x00,0x14,0x80,0x40], pwd: [0,0,0,0], freq: ulFreq), "config PWD clear"),
            (lfModeCmd(0x05, freq: ulFreq), "LF read-mode"),
            (lfRead(freq: ulFreq), "verify read"),
        ], gap: 0.2)
    }
    func handleUnlockT5(_ bytes: [UInt8]) {
        let emid = recEMid(bytes)
        switch ulPhase {
        case .baseline:
            if !ulAwaitRead {                                   // RF-config reply → now read the id
                ulAwaitRead = true
                afterDelay(ulGap) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.ulFreq), "read id") }
                return
            }
            guard let id = emid else {                          // waiting for a readable id
                ulReadRetries += 1
                if ulReadRetries < 8 { afterDelay(ulGap) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.ulFreq), "read id") }; return }
                ulActive = false; ulPhase = .idle; lfT5Found.stringValue = "no card"
                log("✗ Unlock T5577: no card to read."); return
            }
            ulOrigId = id; ulMarker = id ^ 1                    // a different, still-valid id to probe with
            ulReadRetries = 0; ulIdx = 0; ulPhase = .test
            ulNextKey()
        case .test:
            if !ulAwaitRead { ulStep(); return }                // a write ack arrived → send next command
            if let id = emid {
                if id == ulMarker { ulKeyFound() }              // marker took → this key cleared the password
                else { ulReadRetries = 0; ulIdx += 1; ulNextKey() }   // unchanged → wrong key, next
            } else if ulReadRetries < 3 {                       // read glitch → retry
                ulReadRetries += 1
                afterDelay(ulSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.ulFreq), "probe read") }
            } else { ulReadRetries = 0; ulIdx += 1; ulNextKey() }
        case .idle: break
        }
    }
    func handleUnlock(_ bytes: [UInt8]) {
        guard let id = recEMid(bytes) else {       // no-card read → retry before giving up
            if unlockReadRetries < 6 {
                unlockReadRetries += 1
                sendPayload(lfRead(freq: parseU32(idFreq.stringValue)), "re-read id")
            } else {
                unlockActive = false
                log("✗ unlock: no card detected to read")
            }
            return
        }
        unlockActive = false
        let freq = parseU32(idFreq.stringValue)
        let (w1, w2) = em4100Words(id)
        let keys = allKnownKeys()
        writeExpectId = id; writeExpectEM = unlockEM    // verify read at the end confirms the id survived
        log(String(format: "Unlock: id=%010llX — trying %d known keys (safe: rewrites the same id, no data change)…", id, keys.count))
        var seq: [([UInt8], String)] = [(lfRFConfig(freq: freq), "RF config"), (lfModeCmd(0x14, freq: freq), "LF begin")]
        if unlockEM {
            // EM4305: for each known login key, authenticate and zero the password word (word 2).
            for k in keys {
                seq.append((em4305LoginBytes(pwd: k, freq: freq), "login \(hex(k))"))
                seq.append((em4305WriteWord(addr: 2, bytes: [0,0,0,0], freq: freq), "word2 = 0"))
            }
            // Now unprotected: rewrite data + config with password 0.
            seq.append((em4305LoginBytes(pwd: [0,0,0,0], freq: freq), "login 0"))
            seq.append((em4305WriteWord(addr: 5, bytes: u32be(w1), freq: freq), "w5 data1"))
            seq.append((em4305WriteWord(addr: 6, bytes: u32be(w2), freq: freq), "w6 data2"))
            seq.append((em4305WriteWord(addr: 4, bytes: kEM4305ConfigWire, freq: freq), "w4 config"))
        } else {
            // T5577: for each known key, zero the password block (7). The matching key sets it to 0;
            // wrong keys are rejected (no change). Then clear the PWD bit and rewrite the same id — all
            // with password 0, which now works.
            for k in keys { seq.append((lfT5Write(addr: 7, word: [0,0,0,0], pwd: k, freq: freq), "block7 = 0 (auth \(hex(k)))")) }
            seq.append((lfT5Write(addr: 0, word: [0x00,0x14,0x80,0x40], pwd: [0,0,0,0], freq: freq), "block0 config (PWD clear)"))
            seq.append((lfT5Write(addr: 1, word: u32be(w1), pwd: [0,0,0,0], freq: freq), "block1 (same id)"))
            seq.append((lfT5Write(addr: 2, word: u32be(w2), pwd: [0,0,0,0], freq: freq), "block2 (same id)"))
        }
        seq.append((lfModeCmd(0x05, freq: freq), "LF read-mode"))
        seq.append((lfRead(freq: freq), "verify read"))
        sendSeq(seq, gap: 0.2)
        (unlockEM ? lfEMFound : lfT5Found).stringValue = "swept — now pwd 0"
    }

    func pageConfig() -> NSView {
        // MFRC522 register defaults from the hidden Config panel
        let regs: [(UInt8, UInt8, String)] = [
            (0x18,0x84,"RxThreshold"),(0x26,0x48,"RFCfg"),(0x24,0x26,"ModWidth"),
            (0x23,0x88,"GsNOff"),(0x27,0x88,"GsNOn"),(0x28,0x20,"CWGsP"),(0x29,0x20,"ModGsP")]
        var rows: [NSView] = [head("MFRC522 RF registers (class 0x85)")]
        var pairViews: [NSView] = []
        for (addr,val,name) in regs {
            let tf = NSTextField(string: String(format:"%02X", val)); regFields[addr] = tf
            pairViews.append(labeled(String(format:"%@ (%02X):", name, addr), field(tf, 50)))
        }
        // two columns
        rows.append(hstack(Array(pairViews.prefix(4))))
        rows.append(hstack(Array(pairViews.suffix(from: 4))))
        rows.append(hstack([ActionButton("Write registers (0x85/12)") { [weak self] in self?.writeRegs() },
                            ActionButton("RF config (0x85/32)") { [weak self] in self?.sendPayload([0xFF,0x00,0x85,0x32], "RF config") },
                            ActionButton("Get version (0x1F)") { [weak self] in self?.tx(0x1F) }]))
        return vstack(rows)
    }

    func pageAdvanced() -> NSView {
        let g1 = hstack([
            ActionButton("Toggle 0x6A 01") { [weak self] in self?.sendPayload([0xFF,0x00,0x6A,0x01], "toggle") },
            ActionButton("Slot 0x6B 30") { [weak self] in self?.sendPayload([0xFF,0x00,0x6B,0x30], "slot 30") },
            ActionButton("Slot 0x6B 31") { [weak self] in self?.sendPayload([0xFF,0x00,0x6B,0x31], "slot 31") },
        ])
        let g2 = hstack([
            ActionButton("Attack helper 0x3F") { [weak self] in self?.tx(0x3F) },
            ActionButton("Attack helper 0x4F") { [weak self] in self?.tx(0x4F) },
        ])
        let warn = NSTextField(wrappingLabelWithString: "⚠︎ The Windows app also has hidden firmware Init / Erase / flash buttons (X7V310…-74H). Their opcodes are NOT mapped and are deliberately omitted — a wrong firmware frame can brick the reader. Use the Raw page only if you know the exact bytes.")
        warn.font = NSFont.systemFont(ofSize: 10); warn.textColor = .systemOrange; warn.preferredMaxLayoutWidth = 900
        return vstack([head("Advanced / hidden control opcodes"), g1, g2, warn])
    }

    func pageRaw() -> NSView {
        let row1 = hstack([labeled("Payload (FF 00 …):", field(rawPayload, 420)),
                           ActionButton("Send (framed)") { [weak self] in guard let s=self else {return}; s.sendPayload(parseHexBlob(s.rawPayload.stringValue), "raw payload") }])
        let row2 = hstack([labeled("Full frame (verbatim ≤64B):", field(rawFrame, 420)),
                           ActionButton("Send (verbatim)") { [weak self] in guard let s=self else {return}; s.sendVerbatim(parseHexBlob(s.rawFrame.stringValue), "raw frame") }])
        let note = NSTextField(wrappingLabelWithString: "“Framed” adds 01 LEN 00 00 … CHK FE and the checksum for you. “Verbatim” sends your bytes exactly (padded to 64) — for replaying captures.")
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor; note.preferredMaxLayoutWidth = 900
        return vstack([head("Raw send"), row1, row2, note])
    }

    // MARK: radio actions (single action per group → exclusive behaviour)
    @objc func keyChanged(_ sender: NSButton) { mfUseB = (sender.tag == 1) }
    @objc func sizeChanged(_ sender: NSButton) { sizeS70 = (sender.tag == 1) }

    // MARK: command actions
    func tx(_ op: UInt8, a: UInt32 = 125000, b: UInt32 = 0, extra: [UInt8] = []) {
        var p = transceive(op: op, a: a, b: b); p += extra
        sendPayload(p, String(format: "transceive OP 0x%02X b=%u", Int(op), UInt(b)))
    }
    func mfAuth() {
        let key = parseHexBlob(mfKey.stringValue)
        var extra: [UInt8] = [mfUseB ? 0x01 : 0x00]; extra += key
        tx(0x34, b: parseU32(mfBlock.stringValue), extra: extra)
    }
    func mfRead() { tx(0x32, b: parseU32(mfBlock.stringValue)) }
    func mfWrite() { tx(0x33, b: parseU32(mfBlock.stringValue), extra: Array(parseHexBlob(mfData.stringValue).prefix(16))) }
    func mfReadSector0() { tx(0x32, b: 0) }
    func mfDumpAll() {
        let blocks = sizeS70 ? 256 : 64
        log("» dump all \(blocks) blocks")
        for blk in 0..<blocks { tx(0x32, b: UInt32(blk)) }
    }
    func ntagRead() { tx(0x42, b: parseU32(ntagPage.stringValue)) }
    func ntagWrite() { tx(0x33, b: parseU32(ntagPage.stringValue), extra: Array(parseHexBlob(ntagData.stringValue).prefix(4))) }
    func ntagReadAll() { for p in 0..<135 { tx(0x42, b: UInt32(p)) } }
    func writeRegs() {
        var body: [UInt8] = [0xFF,0x00,0x85,0x12]
        for (addr, tf) in regFields.sorted(by: { $0.key < $1.key }) { body.append(addr); body.append(parseByte(tf.stringValue)) }
        sendPayload(body, "write RC522 registers")
    }

    // MARK: send / receive
    func sendPayload(_ payload: [UInt8], _ label: String) {
        let frame = Frame.build(payload: payload)
        log("» \(label)")
        hid.send(frame, reportID: 0)
    }
    func sendVerbatim(_ bytes: [UInt8], _ label: String) {
        var b = bytes; if b.count < 64 { b += [UInt8](repeating: 0, count: 64 - b.count) }
        hid.send(Array(b.prefix(64)), reportID: 0)
        log("» \(label) (verbatim)")
    }

    func wireHID() {
        hid.onLog = { [weak self] s in DispatchQueue.main.async { self?.log(s) } }
        hid.onConnect = { [weak self] label in self?.statusField.stringValue = "Connected: \(label)"; self?.statusField.textColor = .systemGreen }
        hid.onDisconnect = { [weak self] in self?.statusField.stringValue = "Not connected"; self?.statusField.textColor = .systemRed }
        hid.onReport = { [weak self] bytes in self?.gotReport(bytes) }
    }
    @objc func rescan() { hid.stop(); if !hid.start() { log("restart failed") } }

    func gotReport(_ bytes: [UInt8]) {
        log("RX \(hex(bytes))")
        respRaw.string = hexDump(bytes)
        let p = parseResponse(bytes)
        fStatus.stringValue = p.status
        fLen.stringValue = p.length.isEmpty ? "—" : p.length
        fUID.stringValue = p.uid.isEmpty ? "—" : p.uid
        fPayload.stringValue = p.payloadHex.isEmpty ? "—" : p.payloadHex
        fAscii.stringValue = p.ascii.isEmpty ? "—" : p.ascii
        if recPhase != .idle { handleRecovery(bytes) }
        else if ulActive { handleUnlockT5(bytes) }
        else if unlockActive { handleUnlock(bytes) }
        else if reviveActive { handleRevive(bytes) }
        else if let want = writeExpectId, let id = recEMid(bytes) {   // verify a write actually took
            writeExpectId = nil
            if id == want {
                log(String(format: "✓ write verified: card now reads %010llX.", id))
            } else {
                log(String(format: "✗ write did NOT take: card still reads %010llX (wanted %010llX).", id, want))
                log("  The device ACKs (02 07 00) but the chip still reads the old id. Use \u{201C}Revive LF (rewrite)\u{201D} or \u{201C}Write all LF\u{201D} — they normalise the password and write op12+op13, which is what the original app does to write/revive a protected card.")
            }
        }
        else if let id = recEMid(bytes) { lfWriteId.stringValue = String(id) }  // Read ID → Card #
    }

    func log(_ s: String) {
        let ts = String(ISO8601DateFormatter().string(from: Date()).dropFirst(11).prefix(8))
        NSLog("wCopyTool: %@", s)   // also to stderr/Console — visible when run from Terminal
        logView.textStorage?.append(NSAttributedString(string: "[\(ts)] \(s)\n",
            attributes: [.font: mono(10), .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
    }
    func hexDump(_ bytes: [UInt8]) -> String {
        var lines = [String](); var i = 0
        while i < bytes.count {
            let slice = Array(bytes[i..<min(i+16, bytes.count)])
            let h = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let a = slice.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%04X  %-47@  %@", i, h as NSString, a as NSString)); i += 16
        }
        return lines.joined(separator: "\n")
    }
}
