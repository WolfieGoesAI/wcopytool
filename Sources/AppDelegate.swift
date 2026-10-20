import Cocoa

// Monospaced font with a Mojave (10.14) fallback — monospacedSystemFont is 10.15+.
func mono(_ size: CGFloat) -> NSFont {
    if #available(macOS 10.15, *) {
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    return NSFont(name: "Menlo", size: size) ?? NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size)
}

// Tree nodes for the command outline
final class Node: NSObject {
    let title: String
    let command: Command?
    var children: [Node]
    init(title: String, command: Command? = nil, children: [Node] = []) {
        self.title = title; self.command = command; self.children = children
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {

    let hid = HIDTransport()
    var window: NSWindow!

    // UI
    let statusField = NSTextField(labelWithString: "Not connected")
    let prependToggle = NSButton(checkboxWithTitle: "Prepend report-ID byte (send 65B)", target: nil, action: nil)
    var outline: NSOutlineView!
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    var paramsStack: NSStackView!
    let requestPreview = NSTextField(labelWithString: "")
    let sendButton = NSButton(title: "Send", target: nil, action: nil)

    // response fields
    let fStatus  = NSTextField(labelWithString: "—")
    let fUID     = NSTextField(labelWithString: "—")
    let fATQA    = NSTextField(labelWithString: "—")
    let fSAK     = NSTextField(labelWithString: "—")
    let fATS     = NSTextField(labelWithString: "—")
    let fVersion = NSTextField(labelWithString: "—")
    let respRaw  = NSTextView()
    var logView: NSTextView!

    var roots: [Node] = []
    var currentCommand: Command?
    var paramFields: [NSTextField] = []

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        buildTree()
        buildWindow()
        wireHID()
        if !hid.start() { log("Could not start HID manager.") }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { hid.stop() }

    func buildTree() {
        roots = CmdCategory.allCases.map { cat in
            Node(title: cat.rawValue, children: kCommands.filter { $0.category == cat }.map { Node(title: $0.title, command: $0) })
        }
    }

    // MARK: window / layout

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1040, height: 680)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "wCopyTool — nfcPro HID console"
        window.center()
        let content = NSView(frame: rect)
        window.contentView = content

        // top bar
        let connectBtn = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        statusField.textColor = .systemRed
        let top = NSStackView(views: [statusField, NSView(), prependToggle, connectBtn])
        top.orientation = .horizontal
        top.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top)

        // left: command outline
        outline = NSOutlineView()
        outline.headerView = nil
        outline.rowSizeStyle = .default
        let col = NSTableColumn(identifier: .init("c"))
        col.width = 260
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.indentationPerLevel = 14
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.borderType = .bezelBorder
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outlineScroll)

        // right: detail + params + preview + send
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        paramsStack = NSStackView()
        paramsStack.orientation = .vertical
        paramsStack.alignment = .leading
        paramsStack.spacing = 6
        requestPreview.font = mono(11)
        requestPreview.textColor = .systemBlue
        requestPreview.lineBreakMode = .byCharWrapping
        requestPreview.maximumNumberOfLines = 4
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"

        let reqBox = NSStackView(views: [
            sectionTitle("Command"),
            detailLabel,
            sectionTitle("Parameters"),
            paramsStack,
            sectionTitle("Request (framed bytes)"),
            requestPreview,
            sendButton,
        ])
        reqBox.orientation = .vertical
        reqBox.alignment = .leading
        reqBox.spacing = 8
        reqBox.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        // response fields grid
        func rowFor(_ name: String, _ f: NSTextField) -> NSStackView {
            let l = NSTextField(labelWithString: name); l.alignment = .right
            l.font = NSFont.boldSystemFont(ofSize: 11)
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            f.font = mono(11)
            f.textColor = .labelColor; f.isSelectable = true
            let r = NSStackView(views: [l, f]); r.orientation = .horizontal; r.spacing = 8
            return r
        }
        let fieldsBox = NSStackView(views: [
            sectionTitle("Parsed response"),
            rowFor("Status", fStatus), rowFor("UID", fUID), rowFor("ATQA", fATQA),
            rowFor("SAK", fSAK), rowFor("ATS", fATS), rowFor("Version", fVersion),
            sectionTitle("Raw response"),
        ])
        fieldsBox.orientation = .vertical
        fieldsBox.alignment = .leading
        fieldsBox.spacing = 6
        fieldsBox.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        respRaw.isEditable = false
        respRaw.font = mono(11)
        let respScroll = NSScrollView(); respScroll.documentView = respRaw
        respScroll.hasVerticalScroller = true; respScroll.borderType = .bezelBorder
        respScroll.translatesAutoresizingMaskIntoConstraints = false

        let rightTop = NSStackView(views: [reqBox, fieldsBox])
        rightTop.orientation = .horizontal
        rightTop.alignment = .top
        rightTop.distribution = .fillEqually
        rightTop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rightTop)
        content.addSubview(respScroll)

        // log
        logView = NSTextView()
        logView.isEditable = false
        logView.font = mono(10)
        let logScroll = NSScrollView(); logScroll.documentView = logView
        logScroll.hasVerticalScroller = true; logScroll.borderType = .bezelBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(logScroll)

        // constraints
        let g = content
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: g.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),

            outlineScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            outlineScroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            outlineScroll.widthAnchor.constraint(equalToConstant: 280),
            outlineScroll.bottomAnchor.constraint(equalTo: logScroll.topAnchor, constant: -10),

            rightTop.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            rightTop.leadingAnchor.constraint(equalTo: outlineScroll.trailingAnchor, constant: 10),
            rightTop.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            rightTop.heightAnchor.constraint(equalToConstant: 300),

            respScroll.topAnchor.constraint(equalTo: rightTop.bottomAnchor, constant: 8),
            respScroll.leadingAnchor.constraint(equalTo: rightTop.leadingAnchor),
            respScroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            respScroll.bottomAnchor.constraint(equalTo: logScroll.topAnchor, constant: -10),

            logScroll.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            logScroll.heightAnchor.constraint(equalToConstant: 150),
            logScroll.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
        ])

        window.makeKeyAndOrderFront(nil)
        for r in roots { outline.expandItem(r) }
    }

    func sectionTitle(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.boldSystemFont(ofSize: 11)
        t.textColor = .tertiaryLabelColor
        return t
    }

    // MARK: HID wiring

    func wireHID() {
        hid.onLog = { [weak self] s in DispatchQueue.main.async { self?.log(s) } }
        hid.onConnect = { [weak self] label in
            self?.statusField.stringValue = "Connected: \(label)"
            self?.statusField.textColor = .systemGreen
        }
        hid.onDisconnect = { [weak self] in
            self?.statusField.stringValue = "Not connected"
            self?.statusField.textColor = .systemRed
        }
        hid.onReport = { [weak self] bytes in self?.gotReport(bytes) }
    }

    @objc func rescan() { hid.stop(); if !hid.start() { log("restart failed") } }

    // MARK: outline data source/delegate

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        return (item as! Node).children.count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        return (item as! Node).children[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! Node).children.isEmpty
    }
    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        let id = NSUserInterfaceItemIdentifier("cell")
        let tf = (ov.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = id; return t
        }()
        tf.stringValue = node.title
        tf.font = node.command == nil ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 12)
        return tf
    }
    func outlineViewSelectionDidChange(_ note: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, let cmd = node.command else { return }
        selectCommand(cmd)
    }

    // MARK: command selection + sending

    func selectCommand(_ cmd: Command) {
        currentCommand = cmd
        detailLabel.stringValue = cmd.detail
        // rebuild param fields
        for v in paramsStack.arrangedSubviews { v.removeFromSuperview() }
        paramFields = []
        for p in cmd.params {
            let lbl = NSTextField(labelWithString: p.name + ":")
            lbl.font = NSFont.systemFont(ofSize: 11)
            let tf = NSTextField(string: p.defaultValue)
            tf.font = mono(11)
            tf.widthAnchor.constraint(equalToConstant: 220).isActive = true
            tf.delegate = self
            paramFields.append(tf)
            let row = NSStackView(views: [lbl, tf]); row.orientation = .horizontal; row.spacing = 6
            paramsStack.addArrangedSubview(row)
        }
        updatePreview()
    }

    func controlTextDidChange(_ note: Notification) { updatePreview() }

    func currentBytes() -> (frame: [UInt8], verbatim: Bool) {
        guard let cmd = currentCommand else { return ([], false) }
        let args = paramFields.map { $0.stringValue }
        let built = cmd.make(args)
        if cmd.id == "rawFrame" {
            // sent verbatim, padded to 64
            var b = built; if b.count < 64 { b += [UInt8](repeating: 0, count: 64 - b.count) }
            return (Array(b.prefix(64)), true)
        }
        return (Frame.build(payload: built), false)
    }

    func updatePreview() {
        let (frame, verbatim) = currentBytes()
        var out = frame
        if prependToggle.state == .on && !verbatim { out = [0x00] + out }
        requestPreview.stringValue = hex(out)
    }

    @objc func sendTapped() {
        guard currentCommand != nil else { return }
        let (frame, verbatim) = currentBytes()
        var out = frame
        if prependToggle.state == .on && !verbatim { out = [0x00] + out }
        hid.send(out, reportID: 0)
    }

    func gotReport(_ bytes: [UInt8]) {
        log("RX \(hex(bytes))")
        // raw dump
        respRaw.string = hexDump(bytes)
        // parsed
        let p = parseResponse(bytes)
        fStatus.stringValue  = p.status + (p.note.isEmpty ? "" : "  (\(p.note))")
        fUID.stringValue     = p.uid.isEmpty ? "—" : p.uid
        fATQA.stringValue    = p.atqa.isEmpty ? "—" : p.atqa
        fSAK.stringValue     = p.sak.isEmpty ? "—" : p.sak
        fATS.stringValue     = p.ats.isEmpty ? "—" : p.ats
        fVersion.stringValue = p.version.isEmpty ? "—" : p.version
    }

    // MARK: log

    func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logView.textStorage?.append(NSAttributedString(
            string: "[\(ts)] \(s)\n",
            attributes: [.font: mono(10),
                         .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
    }

    func hexDump(_ bytes: [UInt8]) -> String {
        var lines = [String]()
        var i = 0
        while i < bytes.count {
            let slice = Array(bytes[i..<min(i+16, bytes.count)])
            let h = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let a = slice.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%04X  %-47@  %@", i, h as NSString, a as NSString))
            i += 16
        }
        return lines.joined(separator: "\n")
    }
}
