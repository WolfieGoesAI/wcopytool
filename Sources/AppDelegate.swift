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
    // Editable known-password list (Passwords tab) used by Unlock/Write, seeded from the defaults.
    var keyList: [String] = defaultLFKeys()
    var pwdEditor: NSTextView!
    var pwdMirror: NSTextView!

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
    let idFormat = NSPopUpButton()                    // how the Card # field is read/shown
    var cardFmt = 0                                   // current Card # format index
    let lfFormats = NSTextField(wrappingLabelWithString: "")   // Proxmark-style breakdown
    let lfPwd = NSTextField(string: "00000000")
    let hidFC = NSTextField(string: "0")
    let hidCN = NSTextField(string: "0")
    let hidFmtPop = NSPopUpButton()
    let hidInfo = NSTextField(wrappingLabelWithString: "")
    let hidProtect = NSButton(checkboxWithTitle: "Write-protect with password:", target: nil, action: nil)
    let hidPwd = NSTextField(string: "00000000")
    let hidUnlock = NSTextField(string: "00000000")   // the card's CURRENT password (for re-writing a protected card)
    let lfProtect = NSButton(checkboxWithTitle: "Password-protect written card with password:", target: nil, action: nil)
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
            ("HID Prox", pageHID()),
            ("Passwords", pagePasswords()),
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
        // Confirmed LF read: FF 00 65 05 1E <freq> 00 00 00 00 → reply 02 0C 01 00 05 <5-byte EM id> CHK FD
        // Frequency is fixed at 125 kHz — every LF command in the original app uses it, and EM4100 /
        // T5577 are 125 kHz chips. (idFreq stays at 125000 internally.)
        let readRow = hstack([ActionButton("Read ID (EM4100)") { [weak self] in
                                  guard let s = self else { return }
                                  s.sendPayload(lfRead(freq: parseU32(s.idFreq.stringValue)), "LF read EM4100") }])
        // Card # with a format selector (how the field is read and displayed).
        if idFormat.numberOfItems == 0 {
            idFormat.addItems(withTitles: ["Decimal", "Hex (40-bit)", "DEZ 8", "DEZ 5.5", "Wiegand 26"])
            idFormat.target = self; idFormat.action = #selector(idFormatChanged)
            lfWriteId.target = self; lfWriteId.action = #selector(cardIdEdited)
        }
        // Write — rewrites all LF chip types (T5577 + EM4305) the way the original app does.
        let writeRow = hstack([labeled("Card #:", field(lfWriteId, 130)), labeled("as", idFormat),
                               ActionButton("Write T5577") { [weak self] in self?.writeEM(false) },
                               ActionButton("Write EM4305") { [weak self] in self?.writeEM(true) },
                               ActionButton("Write all LF") { [weak self] in guard let s = self else { return }
                                   s.writeLFAll(id: s.currentCardId()) }])
        // All formats of the current id (Proxmark-style).
        lfFormats.font = mono(10); lfFormats.textColor = .secondaryLabelColor; lfFormats.preferredMaxLayoutWidth = 900
        refreshFormats(currentCardId())
        // Protection for the written card: unchecked = no password; checked = lock with the password.
        let protectRow = hstack([lfProtect, field(lfPwd, 100)])
        // Unlock finds the card's current password (tries known keys + the password fields), clears
        // it, and writes the found password into the Unlock Password field.
        let foundRow = hstack([
            labeled("T5577 Unlock Password:", field(lfT5Found, 100)),
            ActionButton("Unlock T5577") { [weak self] in self?.unlockCard(false) },
            labeled("EM4305 Unlock Password:", field(lfEMFound, 100)),
            ActionButton("Unlock EM4305") { [weak self] in self?.unlockCard(true) }])
        return vstack([readRow, writeRow, lfFormats, protectRow, foundRow])
    }

    // ---- Card-number formats (EM4100 / Proxmark style) ----
    // The 40-bit id is the canonical value; the Card # field shows/edits it in the selected format.
    func parseCardId(_ s: String, _ fmt: Int) -> UInt64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        switch fmt {
        case 1: return (UInt64(t.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: " ", with: ""), radix: 16) ?? 0) & 0xFF_FFFF_FFFF
        case 2: return (UInt64(t) ?? 0) & 0xFF_FFFF          // DEZ 8 → lower 24 bits
        case 3:                                               // DEZ 5.5 "AAAAA.BBBBB"
            let p = t.split(separator: ".")
            let a = p.count > 0 ? (UInt64(p[0]) ?? 0) : 0
            let b = p.count > 1 ? (UInt64(p[1]) ?? 0) : 0
            return ((a & 0xFFFF) << 16) | (b & 0xFFFF)
        case 4:                                               // Wiegand 26 "FC,CN"
            let p = t.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            let fc = p.count > 0 ? (UInt64(p[0]) ?? 0) : 0
            let cn = p.count > 1 ? (UInt64(p[1]) ?? 0) : 0
            return wiegand26(fc, cn)
        default: return (UInt64(t) ?? 0) & 0xFF_FFFF_FFFF    // Decimal (full 40-bit)
        }
    }
    func formatCardId(_ id: UInt64, _ fmt: Int) -> String {
        switch fmt {
        case 1: return String(format: "%010llX", id)
        case 2: return String(format: "%08llu", id & 0xFFFFFF)
        case 3: return String(format: "%05llu.%05llu", (id >> 16) & 0xFFFF, id & 0xFFFF)
        case 4: return "\((id >> 17) & 0xFF),\((id >> 1) & 0xFFFF)"
        default: return String(id & 0xFF_FFFF_FFFF)
        }
    }
    // H10301 26-bit Wiegand frame (even parity | 8 FC | 16 CN | odd parity) as a 26-bit number.
    func wiegand26(_ fc: UInt64, _ cn: UInt64) -> UInt64 {
        let f = fc & 0xFF, c = cn & 0xFFFF
        let top12 = (f << 4) | ((c >> 12) & 0xF)
        let bot12 = c & 0xFFF
        let ep = UInt64(top12.nonzeroBitCount % 2)            // even parity over the top 12 data bits
        let op = UInt64((bot12.nonzeroBitCount + 1) % 2)      // odd parity over the bottom 12 data bits
        return (ep << 25) | (f << 17) | (c << 1) | op
    }
    func currentCardId() -> UInt64 { parseCardId(lfWriteId.stringValue, cardFmt) }
    func setCardId(_ id: UInt64) { lfWriteId.stringValue = formatCardId(id, cardFmt); refreshFormats(id) }
    func refreshFormats(_ id: UInt64) {
        let fc = (id >> 17) & 0xFF, cn = (id >> 1) & 0xFFFF
        lfFormats.stringValue = String(format:
            "Hex (40-bit) : %010llX      Decimal : %llu\nDEZ 10 : %010llu   DEZ 8 : %08llu   DEZ 5.5 : %05llu.%05llu\nWiegand 26 : FC %llu  CN %llu",
            id, id & 0xFF_FFFF_FFFF, id & 0xFFFFFFFF, id & 0xFFFFFF, (id >> 16) & 0xFFFF, id & 0xFFFF, fc, cn)
    }
    @objc func cardIdEdited() { refreshFormats(currentCardId()) }
    @objc func idFormatChanged() {
        let id = currentCardId()                              // parse with the OLD format
        cardFmt = idFormat.indexOfSelectedItem                // switch
        lfWriteId.stringValue = formatCardId(id, cardFmt)     // redisplay in the new format
        refreshFormats(id)
    }

    // ---- HID Prox (LF, T5577 FSK2a emulation) — read & write verified against the original app ----
    func pageHID() -> NSView {
        hidFC.target = self; hidFC.action = #selector(hidEdited)
        hidCN.target = self; hidCN.action = #selector(hidEdited)
        hidFmtPop.addItems(withTitles: ["HID 26-bit (H10301)", "HID 37-bit (H10304)", "AWID 26-bit"])
        hidFmtPop.selectItem(at: 0)
        hidFmtPop.target = self; hidFmtPop.action = #selector(hidEdited)
        let row = hstack([labeled("Format:", hidFmtPop),
                          labeled("Facility code:", field(hidFC, 80)),
                          labeled("Card number:", field(hidCN, 100)),
                          ActionButton("Read HID") { [weak self] in self?.readHID() },
                          ActionButton("Write HID") { [weak self] in self?.writeHID() },
                          ActionButton("Unlock HID") { [weak self] in self?.startHIDUnlock() }])
        let protRow = hstack([hidProtect, field(hidPwd, 100),
                              labeled("Current card password:", field(hidUnlock, 100))])
        hidInfo.font = mono(10); hidInfo.textColor = .secondaryLabelColor; hidInfo.preferredMaxLayoutWidth = 900
        let note = NSTextField(wrappingLabelWithString: "HID Prox on T5577: config 00107060 (FSK2a, RF/50), data in blocks 1–3. Unchecked = unprotected (config 00107060). Checked = write-protected: config 00107070 (PWD bit set) + the password in block 7. Read auto-detects the format and fills FC/CN. H10301 is 26-bit (8-bit FC / 16-bit CN); H10304 is 37-bit (16-bit FC / 19-bit CN). Current card password: the password already on the card — needed to re-write or unprotect a card you previously locked (leave 00000000 for a blank card); it is remembered automatically after a protected write. Unlock HID identifies the card's password by testing the known keys one at a time (stopping at the one that works), reports it, and converts the card to an unprotected plain EM4100 (the 125 kHz tab's id, or 1 — a real, non-blank id so a direct HID re-write works). The found password is shown in Current card password for reference; the card itself is left unprotected. Re-write it as HID or EM afterwards. AWID 26-bit is write-only (this reader can't read AWID back) and spec-based — verify it on another reader. Paradox and FDX-B follow.")
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor; note.preferredMaxLayoutWidth = 900
        hidRefresh()
        return vstack([head("HID Prox"), row, protRow, hidInfo, note])
    }
    @objc func hidEdited() { hidRefresh() }
    func hidFormat() -> HIDFormat { HIDFormat(rawValue: hidFmtPop.indexOfSelectedItem) ?? .h10301 }
    func hidRefresh() {
        let fc = parseU32(hidFC.stringValue), cn = parseU32(hidCN.stringValue)
        let fmt = hidFormat()
        let b = lfProxBlocks(fmt, fc, cn)
        let name: String
        switch fmt {
        case .h10301: name = "H10301 (HID 26-bit)"
        case .h10304: name = "H10304 (HID 37-bit)"
        case .awid26: name = "AWID 26-bit (write-only, unverified)"
        }
        hidInfo.stringValue = String(format:
            "%@   (FC %u, CN %u)\nT55x7 cfg  : 00107060   blk1 %08X  blk2 %08X  blk3 %08X",
            name, fc, cn, b[0], b[1], b[2])
    }
    func writeHID() {
        guard recPhase == .idle, !ulActive, !hidReadActive, !hidUlActive else { log("busy — another operation is running"); return }
        let fc = parseU32(hidFC.stringValue), cn = parseU32(hidCN.stringValue)
        let freq = parseU32(idFreq.stringValue)
        let fmt = hidFormat()
        let data = lfProxBlocks(fmt, fc, cn)
        let protect = hidProtect.state == .on
        let setPwd = protect ? fieldKey(hidPwd.stringValue) : [0,0,0,0]
        // The card's CURRENT password — needed to re-write or unprotect a card that already has one.
        let cur = fieldKey(hidUnlock.stringValue)
        let fmtName = fmt == .h10301 ? "HID 26-bit" : (fmt == .h10304 ? "HID 37-bit" : "AWID 26-bit")
        log(String(format: "%@ write FC=%u CN=%u → blocks %08X %08X %08X, config %@ (current pwd %@)", fmtName, fc, cn, data[0], data[1], data[2], protect ? "00107070 (locked)" : "00107060", hexJoin(cur)))
        var seq: [([UInt8], String)] = [(lfRFConfig(freq: freq), "RF config")]
        // Set the password (block 7) to the new value, authenticating with the current password, 0, and
        // the known keys — so the change takes whether the card is blank or already protected.
        var b7cands: [[UInt8]] = [cur]; if !b7cands.contains([0,0,0,0]) { b7cands.append([0,0,0,0]) }
        for k in kT5NormalizeKeys { let kb = keyBytes(k); if !b7cands.contains(where: { $0 == kb }) { b7cands.append(kb) } }
        for c in b7cands { seq.append((lfT5Write(addr: 7, word: setPwd, pwd: c, freq: freq), "block7 = new pwd (auth \(hexJoin(c)))")) }
        // HID config: PWD bit (0x10) set only when protecting → 00107070, else 00107060.
        let cfg: [UInt8] = protect ? [0x00,0x10,0x70,0x70] : [0x00,0x10,0x70,0x60]
        let blocks: [(UInt8, [UInt8], String)] = [
            (1, u32be(data[0]), "HID blk1"), (2, u32be(data[1]), "HID blk2"),
            (3, u32be(data[2]), "HID blk3"), (0, cfg, "HID config \(hexJoin(cfg))")]
        // Data/config writes: op12 (no-pwd, open card) then op13 with the new password AND the current
        // password (covers a card still holding its old password before block 7 took effect).
        var dcands: [[UInt8]] = [setPwd]
        for k in [cur, [0,0,0,0]] { if !dcands.contains(where: { $0 == k }) { dcands.append(k) } }
        for (blk, d, name) in blocks {
            seq.append((lfT5WriteNoPwd(addr: blk, word: d, freq: freq), "\(name) op12"))
            for pw in dcands { seq.append((lfT5Write(addr: blk, word: d, pwd: pw, freq: freq), "\(name) op13 (auth \(hexJoin(pw)))")) }
        }
        seq.append((lfModeCmd(0x64, freq: freq), "HID finalize"))   // the op00/0x64 the original sends
        sendSeq(seq, gap: 0.28)
        // Remember the password now on the card so the next write/unprotect can authenticate.
        hidUnlock.stringValue = protect ? (hexJoin(setPwd)) : "00000000"
    }
    var hidReadActive = false
    var hidReadRetries = 0
    func readHID() {
        guard recPhase == .idle, !ulActive, !hidReadActive, !hidUlActive else { log("busy — another operation is running"); return }
        hidReadActive = true; hidReadRetries = 0
        log("Read HID…")
        sendPayload(lfRFConfig(freq: parseU32(idFreq.stringValue)), "RF config")
        afterDelay(0.25) { [weak self] in self?.sendPayload(hidReadCmd(), "read HID") }
    }
    func handleHIDRead(_ bytes: [UInt8]) {
        guard let (p, _, _, _) = Frame.parse(bytes) else { return }
        if let r = hidDecodeReply(p), let fmt = r.fmt {
            hidReadActive = false
            hidFmtPop.selectItem(at: fmt.rawValue)
            hidFC.stringValue = String(r.fc); hidCN.stringValue = String(r.cn); hidRefresh()
            let bits = fmt == .h10301 ? 26 : 37
            log(String(format: "✓ HID read: FC=%u CN=%u  (raw %llX, %d-bit)", r.fc, r.cn, r.raw, bits))
        } else if hidReadRetries < 8 {
            hidReadRetries += 1
            afterDelay(0.2) { [weak self] in self?.sendPayload(hidReadCmd(), "read HID") }
        } else {
            hidReadActive = false
            log("✗ HID read: no HID card detected.")
        }
    }

    // --- HID unlock → plain EM4100, with password identification -----------
    // Identifies which password the locked HID card holds, then converts it to an unprotected plain
    // EM4100. A locked HID card modulates in FSK, so it can't be read as EM up front; instead we test
    // ONE key at a time: clear block 7 with the candidate (op13), write a MARKER EM id + the open EM
    // config 00148040 with password 0, then read back in EM/ASK mode. Only the real password lets those
    // writes land, so a marker read-back identifies the key. Wrong keys change nothing (every write is
    // rejected) — the card stays a locked HID. On a match we rewrite the real id and report the key.
    // The final card is an unprotected plain EM4100 (a real, non-blank id so a direct HID re-write
    // works). Found password is shown in "Current card password" for reference; the card itself is now
    // unprotected (writes still succeed because the write path always includes password 0).
    enum HIDULPhase { case idle, precheck, test }
    var hidUlActive = false
    var hidUlPhase: HIDULPhase = .idle
    var hidUlKeys: [[UInt8]] = []
    var hidUlIdx = 0
    var hidUlFreq: UInt32 = 125000
    var hidUlQueue: [([UInt8], String)] = []
    var hidUlAwait = false
    var hidUlRetries = 0
    var hidUlEmId: UInt64 = 1
    var hidUlMarker: UInt64 = 0
    let hidUlGap = 0.08
    let hidUlSettle = 0.2
    let kEMUnlockedCfg: [UInt8] = [0x00,0x14,0x80,0x40]     // EM4100 config, PWD bit (0x10) cleared
    func hidUnlockKeys() -> [[UInt8]] {
        var keys: [[UInt8]] = []
        func add(_ k: [UInt8]) { if !keys.contains(where: { $0 == k }) { keys.append(k) } }
        add([0,0,0,0])                                      // already-unprotected / blank
        add(fieldKey(hidUnlock.stringValue))                // the card's current password, if known
        add(fieldKey(hidPwd.stringValue))                   // the protect password set here
        add(fieldKey(lfT5Found.stringValue))                // T5577 Unlock Password field
        for k in kT5NormalizeKeys { add(keyBytes(k)) }      // C0F5009A, 19920427, 1C0B5848, Tian
        for k in defaultLFKeys() { add(keyBytes(k)) }       // any other known keys
        return keys
    }
    func startHIDUnlock() {
        guard recPhase == .idle, !ulActive, !hidReadActive, !hidUlActive else { log("busy — another operation is running"); return }
        hidUlActive = true; hidUlPhase = .precheck; hidUlIdx = 0; hidUlRetries = 0; hidUlAwait = false
        hidUlFreq = parseU32(idFreq.stringValue)
        hidUlKeys = hidUnlockKeys()
        hidUlEmId = currentCardId() == 0 ? UInt64(1) : currentCardId()
        hidUlMarker = hidUlEmId ^ 1                          // distinct probe id; real id restored on match
        log(String(format: "Unlock HID: identifying the card's password (testing %d key(s)), then converting to plain EM4100 id %010llX…", hidUlKeys.count, hidUlEmId))
        hidUnlock.stringValue = "unlocking…"
        sendPayload(lfRFConfig(freq: hidUlFreq), "RF config")
        afterDelay(hidUlSettle) { [weak self] in guard let s = self else { return }
            s.hidUlAwait = true; s.sendPayload(lfRead(freq: s.hidUlFreq), "precheck read") }
    }
    func hidUlStep() {
        if !hidUlQueue.isEmpty { let c = hidUlQueue.removeFirst(); afterDelay(hidUlGap) { [weak self] in self?.sendPayload(c.0, c.1) } }
        else { hidUlAwait = true; hidUlRetries = 0; afterDelay(hidUlSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.hidUlFreq), "probe read") } }
    }
    // Per-key probe: clear block 7 with the candidate, then write the MARKER EM id + open config with
    // password 0. Only the real password lets block 7 clear, after which the pwd-0 writes take and the
    // card flips to plain EM; a wrong key leaves everything rejected and the card a locked HID.
    func hidUlProbeQueue(_ k: [UInt8]) -> [([UInt8], String)] {
        let (w1, w2) = em4100Words(hidUlMarker)
        return [
            (lfT5Write(addr: 7, word: [0,0,0,0], pwd: k, freq: hidUlFreq), "clear pwd auth \(hexJoin(k))"),
            (lfT5WriteNoPwd(addr: 1, word: u32be(w1), freq: hidUlFreq), "probe blk1 op12"),
            (lfT5Write(addr: 1, word: u32be(w1), pwd: [0,0,0,0], freq: hidUlFreq), "probe blk1 op13"),
            (lfT5WriteNoPwd(addr: 2, word: u32be(w2), freq: hidUlFreq), "probe blk2 op12"),
            (lfT5Write(addr: 2, word: u32be(w2), pwd: [0,0,0,0], freq: hidUlFreq), "probe blk2 op13"),
            (lfT5WriteNoPwd(addr: 0, word: kEMUnlockedCfg, freq: hidUlFreq), "probe cfg op12"),
            (lfT5Write(addr: 0, word: kEMUnlockedCfg, pwd: [0,0,0,0], freq: hidUlFreq), "probe cfg op13"),
            (lfModeCmd(0x05, freq: hidUlFreq), "LF read-mode"),
        ]
    }
    func hidUlNextKey() {
        guard hidUlIdx < hidUlKeys.count else {
            hidUlActive = false; hidUlPhase = .idle
            hidUnlock.stringValue = "00000000"
            log("✗ Unlock HID: none of \(hidUlKeys.count) known keys unlocked the card — its password isn't in the known set. The card is unchanged.")
            return
        }
        hidUlQueue = hidUlProbeQueue(hidUlKeys[hidUlIdx]); hidUlAwait = false; hidUlStep()
    }
    func hidUlKeyFound() {
        let k = hidUlKeys[hidUlIdx]
        hidUlActive = false; hidUlPhase = .idle
        // Card is now an unprotected plain EM holding the MARKER id — rewrite the real id and verify.
        let (w1, w2) = em4100Words(hidUlEmId)
        writeExpectId = hidUlEmId; writeExpectEM = false
        let seq: [([UInt8], String)] = [
            (lfT5WriteNoPwd(addr: 1, word: u32be(w1), freq: hidUlFreq), "restore blk1"),
            (lfT5WriteNoPwd(addr: 2, word: u32be(w2), freq: hidUlFreq), "restore blk2"),
            (lfT5WriteNoPwd(addr: 0, word: kEMUnlockedCfg, freq: hidUlFreq), "cfg 00148040"),
            (lfModeCmd(0x05, freq: hidUlFreq), "LF read-mode"),
            (lfRead(freq: hidUlFreq), "verify read"),
        ]
        sendSeq(seq, gap: 0.2)
        hidProtect.state = .off
        hidPwd.stringValue = "00000000"
        hidUnlock.stringValue = hexJoin(k)                  // show the found (old) password for reference
        if k == [0,0,0,0] { log(String(format: "✓ Unlock HID: card had no password; converted to an unprotected plain EM4100 id %010llX.", hidUlEmId)) }
        else { log(String(format: "✓ Unlock HID: password was %@ — removed; card converted to an unprotected plain EM4100 id %010llX. (The old password is shown in Current card password for reference; the card itself is now unprotected.)", hexJoin(k), hidUlEmId)) }
    }
    func handleHIDUnlock(_ bytes: [UInt8]) {
        let emid = recEMid(bytes)
        switch hidUlPhase {
        case .precheck:
            if let id = emid {                              // already reads as plain EM → not a locked HID
                hidUlActive = false; hidUlPhase = .idle
                hidUnlock.stringValue = "00000000"
                log(String(format: "Unlock HID: card already reads as a plain EM4100 (id %010llX) — not a locked HID card, nothing to unlock.", id))
                return
            }
            if hidUlRetries < 3 {
                hidUlRetries += 1
                afterDelay(hidUlSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.hidUlFreq), "precheck read") }
                return
            }
            hidUlRetries = 0; hidUlIdx = 0; hidUlPhase = .test; hidUlNextKey()   // locked → sweep keys
        case .test:
            if !hidUlAwait { hidUlStep(); return }          // a write ack arrived → send the next command
            if let id = emid {
                if id == hidUlMarker { hidUlKeyFound() }     // marker took → this key is the password
                else { hidUlRetries = 0; hidUlIdx += 1; hidUlNextKey() }   // unchanged → wrong key, next
            } else if hidUlRetries < 3 {                    // read glitch → retry
                hidUlRetries += 1
                afterDelay(hidUlSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.hidUlFreq), "probe read") }
            } else { hidUlRetries = 0; hidUlIdx += 1; hidUlNextKey() }
        case .idle: break
        }
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
        let id = currentCardId()
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
    // The password to store (block 7 / word 2) on the next write: the Write Lock Password when
    // Password-protect is ticked (card write-protected), else 0 (unprotected).
    func targetPwd() -> [UInt8] { protectOn() ? fieldKey(lfPwd.stringValue) : [0,0,0,0] }
    // Parse a text field as a 4-byte key only when it is exactly 8 hex digits; otherwise 0 (so
    // status text like "swept — now pwd 0" is treated as no password, not garbage).
    func fieldKey(_ s: String) -> [UInt8] {
        let h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        return (h.count == 8 && h.allSatisfy { $0.isHexDigit }) ? keyBytes(h) : [0,0,0,0]
    }

    // Current-password candidates for a Write: the Unlock Password field, and 0 (unprotected / just
    // unlocked). Per the rule "write a non-protected card OR use the field password" — exactly these
    // two, deduped. NOT a full sweep (that's Unlock's job).
    func writeAuthCands(_ field: NSTextField) -> [[UInt8]] {
        var c: [[UInt8]] = [fieldKey(field.stringValue)]
        if !c.contains([0,0,0,0]) { c.append([0,0,0,0]) }
        return c
    }
    // T5577 write. Authenticates with the T5577 Unlock Password field OR 0 (unprotected). Sets the
    // new password to the Write Lock Password when the checkbox is ticked, else leaves it unprotected.
    // If neither candidate is the card's real password the writes are rejected and the card is unchanged.
    func t5577Seq(id: UInt64) -> [([UInt8], String)] {
        let freq = parseU32(idFreq.stringValue)
        let (w1, w2) = em4100Words(id)
        let setPwd = targetPwd()                         // new password to set
        let cfg: [UInt8] = protectOn() ? [0x00,0x14,0x80,0x50] : [0x00,0x14,0x80,0x40]
        var seq: [([UInt8], String)] = []
        // Change the password (block 7) to the new value, authenticating with each candidate.
        for c in writeAuthCands(lfT5Found) {
            seq.append((lfT5Write(addr: 7, word: setPwd, pwd: c, freq: freq), "block7 = new pwd (auth \(hexJoin(c)))"))
        }
        // Then write data + config, authenticating with the (now) new password.
        for (blk, data, name) in [(UInt8(1), u32be(w1), "block1"), (2, u32be(w2), "block2"), (0, cfg, "block0 cfg")] {
            seq.append((lfT5WriteNoPwd(addr: blk, word: data, freq: freq), "\(name) op12"))
            seq.append((lfT5Write(addr: blk, word: data, pwd: setPwd, freq: freq), "\(name) op13"))
        }
        return seq
    }
    // EM4305 write. Authenticates with the EM4305 Unlock Password field OR 0, sets the new password
    // from the Write Lock Password when the checkbox is ticked, else leaves it unprotected.
    func em4305Seq(id: UInt64) -> [([UInt8], String)] {
        let freq = parseU32(idFreq.stringValue)
        let (w1, w2) = em4100Words(id)
        let setPwd = targetPwd()
        var seq: [([UInt8], String)] = []
        // Set word2 = new password, authenticating (login) with each candidate current password.
        for c in writeAuthCands(lfEMFound) {
            seq.append((em4305LoginBytes(pwd: c, freq: freq), "login (current \(hexJoin(c)))"))
            seq.append((em4305WriteWord(addr: 2, bytes: setPwd, freq: freq), "word2 = new pwd"))
        }
        // Log in with the new password and write data + config.
        seq.append((em4305LoginBytes(pwd: setPwd, freq: freq), "login (new pwd)"))
        seq.append((em4305WriteWord(addr: 5, bytes: u32be(w1), freq: freq), "word5 data1"))
        seq.append((em4305WriteWord(addr: 6, bytes: u32be(w2), freq: freq), "word6 data2"))
        seq.append((em4305WriteWord(addr: 4, bytes: kEM4305ConfigWire, freq: freq), "word4 cfg"))
        return seq
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
    var unlockActive = false     // retained only for the (now UI-less) read-only recovery guard
    // Every known password, wire-byte form, most-likely first. These are the passwords the original
    // app and this ecosystem use, so an ecosystem card's password is almost always in here.
    func allKnownKeys() -> [[UInt8]] {
        var out: [[UInt8]] = []
        func add(_ b: [UInt8]) { if !out.contains(where: { $0 == b }) { out.append(b) } }
        let typed = fieldKey((ulEM ? lfEMFound : lfT5Found).stringValue)   // the Unlock Password field
        if typed != [0,0,0,0] { add(typed) }
        let wlp = fieldKey(lfPwd.stringValue)           // also try the Write Lock Password field
        if wlp != [0,0,0,0] { add(wlp) }
        for k in keyList where fieldKey(k) != [0,0,0,0] || k.replacingOccurrences(of: " ", with: "") == "00000000" {
            add(keyBytes(k))                             // the editable Passwords-tab list
        }
        return out
    }
    func unlockCard(_ em4305: Bool) {
        guard recPhase == .idle, !ulActive else { log("busy — another operation is running"); return }
        startUnlock(em4305)
    }

    // ---- Identifying unlock (T5577 or EM4305): find WHICH known key unlocks, stop at it, populate
    // the Unlock Password field, restore the id and clear protection. Per key K: authenticate with K
    // and write a MARKER id with no/zero password; only the correct key lets the marker take, so only
    // then does the read change. Safe: only the matching key changes data, and it is restored.
    enum ULPhase { case idle, baseline, precheck, test }
    var ulActive = false
    var ulEM = false
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
    func ulField() -> NSTextField { ulEM ? lfEMFound : lfT5Found }
    func startUnlock(_ em4305: Bool) {
        ulEM = em4305
        ulActive = true; ulPhase = .baseline; ulIdx = 0; ulReadRetries = 0; ulAwaitRead = false
        ulFreq = parseU32(idFreq.stringValue)
        ulKeys = allKnownKeys()
        ulField().stringValue = "unlocking…"
        log("Unlock \(em4305 ? "EM4305" : "T5577"): testing \(ulKeys.count) known keys, stopping at the one that works…")
        sendPayload(lfRFConfig(freq: ulFreq), "RF config")      // gated: its reply triggers the baseline read
    }
    func ulStep() {
        if !ulQueue.isEmpty { let c = ulQueue.removeFirst(); afterDelay(ulGap) { [weak self] in self?.sendPayload(c.0, c.1) } }
        else { ulAwaitRead = true; ulReadRetries = 0; afterDelay(ulSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.ulFreq), "probe read") } }
    }
    // The per-key probe: authenticate with K, then write the marker id. T5577 zeroes block 7 then
    // writes blocks 1/2 with password 0; EM4305 logs in with K then writes words 5/6.
    func ulProbeQueue(_ k: [UInt8]) -> [([UInt8], String)] {
        let (mw1, mw2) = em4100Words(ulMarker)
        if ulEM {
            return [ (em4305LoginBytes(pwd: k, freq: ulFreq), "login \(hexJoin(k))"),
                     (em4305WriteWord(addr: 5, bytes: u32be(mw1), freq: ulFreq), "probe w5"),
                     (em4305WriteWord(addr: 6, bytes: u32be(mw2), freq: ulFreq), "probe w6") ]
        } else {
            return [ (lfT5Write(addr: 7, word: [0,0,0,0], pwd: k, freq: ulFreq), "clear pwd auth \(hexJoin(k))"),
                     (lfT5Write(addr: 1, word: u32be(mw1), pwd: [0,0,0,0], freq: ulFreq), "probe blk1"),
                     (lfT5Write(addr: 2, word: u32be(mw2), pwd: [0,0,0,0], freq: ulFreq), "probe blk2") ]
        }
    }
    // Pre-check: write the marker with NO password / password 0, without changing block 7 or
    // logging in with a key. If it takes, the card is already unprotected (so the sweep would
    // otherwise false-positive on the first key). Only if it's rejected do we sweep.
    func ulPrecheckQueue() -> [([UInt8], String)] {
        let (mw1, mw2) = em4100Words(ulMarker)
        if ulEM {
            return [ (em4305LoginBytes(pwd: [0,0,0,0], freq: ulFreq), "login 0"),
                     (em4305WriteWord(addr: 5, bytes: u32be(mw1), freq: ulFreq), "pre w5"),
                     (em4305WriteWord(addr: 6, bytes: u32be(mw2), freq: ulFreq), "pre w6") ]
        } else {
            return [ (lfT5Write(addr: 1, word: u32be(mw1), pwd: [0,0,0,0], freq: ulFreq), "pre blk1"),
                     (lfT5Write(addr: 2, word: u32be(mw2), pwd: [0,0,0,0], freq: ulFreq), "pre blk2") ]
        }
    }
    func ulUnprotected() {
        ulActive = false; ulPhase = .idle
        ulField().stringValue = "00000000"
        log("✓ Unlock \(ulEM ? "EM4305" : "T5577"): card has no password (not write-protected). Restoring id \(String(format: "%010llX", ulOrigId)).")
        let (w1, w2) = em4100Words(ulOrigId)
        writeExpectId = ulOrigId; writeExpectEM = ulEM
        var seq: [([UInt8], String)]
        if ulEM {
            seq = [ (em4305LoginBytes(pwd: [0,0,0,0], freq: ulFreq), "login 0"),
                    (em4305WriteWord(addr: 5, bytes: u32be(w1), freq: ulFreq), "w5 restore"),
                    (em4305WriteWord(addr: 6, bytes: u32be(w2), freq: ulFreq), "w6 restore"),
                    (lfRead(freq: ulFreq), "verify read") ]
        } else {
            seq = [ (lfT5Write(addr: 1, word: u32be(w1), pwd: [0,0,0,0], freq: ulFreq), "restore blk1"),
                    (lfT5Write(addr: 2, word: u32be(w2), pwd: [0,0,0,0], freq: ulFreq), "restore blk2"),
                    (lfRead(freq: ulFreq), "verify read") ]
        }
        sendSeq(seq, gap: 0.2)
    }
    func ulNextKey() {
        guard ulIdx < ulKeys.count else {
            ulActive = false; ulPhase = .idle
            ulField().stringValue = "not found"
            log("✗ Unlock \(ulEM ? "EM4305" : "T5577"): none of \(ulKeys.count) known keys unlocked the card — its password isn't in the known set.")
            return
        }
        ulQueue = ulProbeQueue(ulKeys[ulIdx]); ulAwaitRead = false; ulStep()
    }
    func ulKeyFound() {
        let k = ulKeys[ulIdx]
        ulActive = false; ulPhase = .idle
        ulField().stringValue = hexJoin(k)                      // <-- found password populates the Unlock field
        log("✓ Unlock \(ulEM ? "EM4305" : "T5577"): password is \(hexJoin(k)). Restoring id \(String(format: "%010llX", ulOrigId)) and clearing protection.")
        let (w1, w2) = em4100Words(ulOrigId)
        writeExpectId = ulOrigId; writeExpectEM = ulEM
        var seq: [([UInt8], String)]
        if ulEM {
            seq = [ (em4305LoginBytes(pwd: k, freq: ulFreq), "login"),
                    (em4305WriteWord(addr: 2, bytes: [0,0,0,0], freq: ulFreq), "word2 = 0"),
                    (em4305LoginBytes(pwd: [0,0,0,0], freq: ulFreq), "login 0"),
                    (em4305WriteWord(addr: 5, bytes: u32be(w1), freq: ulFreq), "w5 restore"),
                    (em4305WriteWord(addr: 6, bytes: u32be(w2), freq: ulFreq), "w6 restore"),
                    (em4305WriteWord(addr: 4, bytes: kEM4305ConfigWire, freq: ulFreq), "w4 cfg"),
                    (lfRead(freq: ulFreq), "verify read") ]
        } else {
            seq = [ (lfT5Write(addr: 1, word: u32be(w1), pwd: [0,0,0,0], freq: ulFreq), "restore blk1"),
                    (lfT5Write(addr: 2, word: u32be(w2), pwd: [0,0,0,0], freq: ulFreq), "restore blk2"),
                    (lfT5Write(addr: 0, word: [0x00,0x14,0x80,0x40], pwd: [0,0,0,0], freq: ulFreq), "config PWD clear"),
                    (lfModeCmd(0x05, freq: ulFreq), "LF read-mode"),
                    (lfRead(freq: ulFreq), "verify read") ]
        }
        sendSeq(seq, gap: 0.2)
    }
    func handleUnlock(_ bytes: [UInt8]) {
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
                ulActive = false; ulPhase = .idle; ulField().stringValue = "no card"
                log("✗ Unlock: no card to read."); return
            }
            ulOrigId = id; ulMarker = id ^ 1                    // a different, still-valid id to probe with
            ulReadRetries = 0; ulPhase = .precheck              // first check if the card is already unprotected
            ulQueue = ulPrecheckQueue(); ulAwaitRead = false; ulStep()
        case .precheck:
            if !ulAwaitRead { ulStep(); return }
            if let id = emid {
                if id == ulMarker { ulUnprotected() }           // no password needed → card is open
                else { ulReadRetries = 0; ulIdx = 0; ulPhase = .test; ulNextKey() }   // protected → sweep keys
            } else if ulReadRetries < 3 {
                ulReadRetries += 1
                afterDelay(ulSettle) { [weak self] in guard let s = self else { return }; s.sendPayload(lfRead(freq: s.ulFreq), "probe read") }
            } else { ulReadRetries = 0; ulIdx = 0; ulPhase = .test; ulNextKey() }
        case .test:
            if !ulAwaitRead { ulStep(); return }                // a write/login ack arrived → send next command
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
        let g0 = hstack([
            ActionButton("Device info (0x68)") { [weak self] in self?.sendPayload([0xFF,0x00,0x68], "device info") },
            ActionButton("Serial number (0x69)") { [weak self] in self?.sendPayload([0xFF,0x00,0x69], "serial") },
        ])
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
        return vstack([head("Advanced / hidden control opcodes"), g0, g1, g2, warn])
    }

    // Editable known-password list (feeds Unlock and Write), shown with bit-reversed + byte-reversed
    // equivalents. Edit the left box (one hex password per line), press Apply.
    func pagePasswords() -> NSView {
        pwdEditor = NSTextView(); let edScroll = makeTextScroll(pwdEditor, mono(11))
        pwdEditor.isEditable = true
        pwdEditor.string = keyList.joined(separator: "\n")
        pwdMirror = NSTextView(); let mirScroll = makeTextScroll(pwdMirror, mono(11))
        let apply = ActionButton("Apply list") { [weak self] in self?.applyKeyList() }
        let reset = ActionButton("Reset to defaults") { [weak self] in guard let s = self else { return }
            s.keyList = defaultLFKeys(); s.pwdEditor.string = s.keyList.joined(separator: "\n"); s.refreshMirror() }
        let cols = hstack([edScroll, mirScroll])
        NSLayoutConstraint.activate([
            edScroll.widthAnchor.constraint(equalToConstant: 180), edScroll.heightAnchor.constraint(equalToConstant: 360),
            mirScroll.widthAnchor.constraint(equalToConstant: 470), mirScroll.heightAnchor.constraint(equalToConstant: 360),
        ])
        let note = NSTextField(wrappingLabelWithString: "One hex password (8 hex digits) per line. These are the keys Unlock tries and the current-password candidates; the two Unlock Password fields and the Write Lock Password are also tried automatically. The right column shows each key with its bit-reversed (binary-mirror) and byte-reversed equivalents — T5577 and EM4305 passwords are sometimes mirrors of each other.")
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor; note.preferredMaxLayoutWidth = 900
        refreshMirror()
        return vstack([head("Known passwords (editable)"), hstack([apply, reset]), cols, note])
    }
    func applyKeyList() {
        var out: [String] = []; var seen = Set<String>()
        for raw in pwdEditor.string.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let h = raw.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "")
            guard h.count == 8, h.allSatisfy({ $0.isHexDigit }) else { continue }
            if !seen.contains(h) { seen.insert(h); out.append(h) }
        }
        keyList = out
        log("Passwords: applied \(keyList.count) keys.")
        refreshMirror()
    }
    func refreshMirror() {
        let header = String(format: "%-10@  %-10@  %@\n", "password" as NSString, "bit-rev" as NSString, "byte-rev" as NSString)
        var lines = [header + String(repeating: "─", count: 34)]
        for k in keyList { lines.append(String(format: "%-10@  %-10@  %@", k as NSString, bitReverse32Hex(k) as NSString, byteReverseHex(k) as NSString)) }
        pwdMirror.string = lines.joined(separator: "\n")
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
        else if hidUlActive { handleHIDUnlock(bytes) }
        else if hidReadActive { handleHIDRead(bytes) }
        else if ulActive { handleUnlock(bytes) }
        else if let want = writeExpectId, let id = recEMid(bytes) {   // verify a write actually took
            writeExpectId = nil
            if id == want {
                log(String(format: "✓ write verified: card now reads %010llX.", id))
            } else {
                log(String(format: "✗ write did NOT take: card still reads %010llX (wanted %010llX).", id, want))
                log("  The device ACKs (02 07 00) but the chip still reads the old id. Use \u{201C}Revive LF (rewrite)\u{201D} or \u{201C}Write all LF\u{201D} — they normalise the password and write op12+op13, which is what the original app does to write/revive a protected card.")
            }
        }
        else if let id = recEMid(bytes) { setCardId(id) }  // Read ID → Card # (in the selected format)
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
