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

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {

    let hid = HIDTransport()
    var window: NSWindow!

    // shared top/bottom
    let statusField = NSTextField(labelWithString: "Not connected")
    let prependToggle = NSButton(checkboxWithTitle: "Prepend report-ID byte", target: nil, action: nil)
    let fUID = NSTextField(labelWithString: "—"); let fATQA = NSTextField(labelWithString: "—")
    let fSAK = NSTextField(labelWithString: "—"); let fATS = NSTextField(labelWithString: "—")
    let fVersion = NSTextField(labelWithString: "—"); let fStatus = NSTextField(labelWithString: "—")
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
        let topBar = hstack([statusField, NSView(), prependToggle, rescan])
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
        let fieldsRow1 = hstack([pair("UID", fUID), pair("ATQA", fATQA), pair("SAK", fSAK)])
        let fieldsRow2 = hstack([pair("ATS", fATS), pair("Ver", fVersion), pair("Status", fStatus)])
        let fieldsBox = vstack([head("Parsed response"), fieldsRow1, fieldsRow2], spacing: 6)
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
        let row1 = hstack([labeled("Freq/A:", field(idFreq, 100)),
                           ActionButton("Read ID (exp 0x12)") { [weak self] in self?.idRead() },
                           ActionButton("Reader ctrl 0x68") { [weak self] in self?.sendPayload([0xFF,0x00,0x68], "ctrl 0x68") },
                           ActionButton("Reader ctrl 0x69") { [weak self] in self?.sendPayload([0xFF,0x00,0x69], "ctrl 0x69") }])
        let note = NSTextField(wrappingLabelWithString: "125 kHz (EM/T5577) opcodes aren't separated out statically — use these experimental sends plus the Raw page to discover the LF path, then tell me and I'll label them.")
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor; note.preferredMaxLayoutWidth = 900
        return vstack([head("125 kHz ID (experimental)"), row1, note])
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
    func idRead() { tx(0x12, a: parseU32(idFreq.stringValue)) }
    func writeRegs() {
        var body: [UInt8] = [0xFF,0x00,0x85,0x12]
        for (addr, tf) in regFields.sorted(by: { $0.key < $1.key }) { body.append(addr); body.append(parseByte(tf.stringValue)) }
        sendPayload(body, "write RC522 registers")
    }

    // MARK: send / receive
    func sendPayload(_ payload: [UInt8], _ label: String) {
        var frame = Frame.build(payload: payload)
        if prependToggle.state == .on { frame = [0x00] + frame }
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
        fStatus.stringValue = p.status + (p.note.isEmpty ? "" : "  (\(p.note))")
        fUID.stringValue = p.uid.isEmpty ? "—" : p.uid
        fATQA.stringValue = p.atqa.isEmpty ? "—" : p.atqa
        fSAK.stringValue = p.sak.isEmpty ? "—" : p.sak
        fATS.stringValue = p.ats.isEmpty ? "—" : p.ats
        fVersion.stringValue = p.version.isEmpty ? "—" : p.version
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
