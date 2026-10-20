import Foundation

// MARK: - Device identifiers (from nfcPro_x64.exe device finder)

struct DeviceID { let vid: Int; let pid: Int; let label: String }

let kKnownDevices: [DeviceID] = [
    DeviceID(vid: 0x0416, pid: 0xB030, label: "wCopy (0416:B030)"),
    DeviceID(vid: 0x0416, pid: 0xB031, label: "wCopy (0416:B031)"),
    DeviceID(vid: 0x2518, pid: 0x6022, label: "wCopy (2518:6022)"),
    DeviceID(vid: 0x2518, pid: 0x6018, label: "wCopy (2518:6018)"),
]

let kReportLength = 64          // bytes, both directions
let kReadTimeoutMs = 2000

// MARK: - Framing

enum Frame {
    static let STX: UInt8 = 0x01       // request STX (responses use 0x02)
    static let ETX: UInt8 = 0xFE       // request ETX (responses use 0xFD)
    static let maxPayload = 0x30   // 48, per the firmware cap

    /// Build a 64-byte report from a payload (payload already begins FF 00 CLASS …).
    /// Layout: 01 LEN 00 00 <payload> CHK FE 00…   LEN = payloadLen + 6
    static func build(payload: [UInt8]) -> [UInt8] {
        let n = min(payload.count, maxPayload)
        var buf = [UInt8](repeating: 0, count: kReportLength)
        buf[0] = STX
        buf[1] = UInt8((n + 6) & 0xFF)
        buf[2] = 0x00
        buf[3] = 0x00
        for i in 0..<n { buf[4 + i] = payload[i] }
        // checksum over bytes [0 .. 3+n]  (STX, LEN, 00, 00, payload)
        var sum: UInt32 = 0
        for i in 0...(3 + n) { sum &+= UInt32(buf[i]) }
        buf[4 + n] = UInt8((~sum) & 0xFF)
        buf[5 + n] = ETX
        return buf
    }

    /// Parse a framed report (request `01 LEN 00 00 … CHK FE` or response `02 LEN ST 00 … CHK FD`).
    /// Returns the data bytes between the 4-byte header and CHK, the STX, the status byte [2],
    /// and whether the checksum verifies.
    static func parse(_ report: [UInt8]) -> (payload: [UInt8], checksumOK: Bool, stx: UInt8, status: UInt8)? {
        guard report.count >= 6, report[0] == 0x01 || report[0] == 0x02 else { return nil }
        let len = Int(report[1])
        guard len >= 6, len <= report.count else { return nil }
        let n = len - 6
        guard 4 + n + 1 < report.count else { return nil }
        let payload = Array(report[4..<(4 + n)])
        let chk = report[4 + n]
        var sum: UInt32 = 0
        for i in 0...(3 + n) { sum &+= UInt32(report[i]) }
        let ok = UInt8((~sum) & 0xFF) == chk
        return (payload, ok, report[0], report[2])
    }
}

// MARK: - Command model

/// A parameter the user can edit before sending a command.
struct CmdParam {
    enum Kind { case byte, u32le, hexBlob }
    let name: String
    let kind: Kind
    var defaultValue: String   // shown/edited as hex (byte/blob) or decimal (u32)
}

enum CmdCategory: String, CaseIterable {
    case control   = "Reader control"
    case detect    = "13.56 MHz detect"
    case mifare    = "Mifare Classic"
    case magic     = "Magic cards"
    case ntag      = "NTAG / pages"
    case config    = "MFRC522 / config"
    case advanced  = "Advanced / hidden"
    case raw       = "Raw"
}

/// One invocable command. `make` turns edited parameter strings into the payload
/// (which always begins FF 00 CLASS …).
struct Command {
    let id: String
    let title: String
    let category: CmdCategory
    let detail: String
    let params: [CmdParam]
    let make: ([String]) -> [UInt8]
}

// Helpers -------------------------------------------------------------

func u32le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v>>8)&0xFF), UInt8((v>>16)&0xFF), UInt8((v>>24)&0xFF)] }

func parseU32(_ s: String) -> UInt32 {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.lowercased().hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) ?? 0 }
    return UInt32(t) ?? 0
}
func parseByte(_ s: String) -> UInt8 {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
    return UInt8(t, radix: 16) ?? 0
}
func parseHexBlob(_ s: String) -> [UInt8] {
    let cleaned = s.filter { $0.isHexDigit }
    var out = [UInt8](); var i = cleaned.startIndex
    while i < cleaned.endIndex {
        let j = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
        if let b = UInt8(cleaned[i..<j], radix: 16) { out.append(b) }
        i = j
    }
    return out
}
func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
func hex(_ bytes: [UInt8]) -> String { hex(bytes[...]) }

// A 14443A transceive payload: FF 00 66 00 1E <A:u32> <OP> <B:u32>
func transceive(op: UInt8, a: UInt32, b: UInt32) -> [UInt8] {
    var p: [UInt8] = [0xFF, 0x00, 0x66, 0x00, 0x1E]
    p += u32le(a)
    p.append(op)
    p += u32le(b)
    return p
}

// 125 kHz LF channel is CLASS 0x65 (confirmed from the Read-ID handler):
//   FF 00 65 <mode> 1E <freq:u32 LE> <a:u16> <b:u16>
// mode 0x05 = read 5-byte EM4100 id. Reply: 02 0C 01 00 05 <5 id bytes> CHK FD.
func lfRead(freq: UInt32 = 125000) -> [UInt8] {
    [0xFF, 0x00, 0x65, 0x05, 0x1E] + u32le(freq) + [0x00, 0x00, 0x00, 0x00]
}
func lf65(mode: UInt8, freq: UInt32 = 125000, tail: [UInt8] = [0,0,0,0]) -> [UInt8] {
    var p: [UInt8] = [0xFF, 0x00, 0x65, mode, 0x1E] + u32le(freq)
    p += tail; return p
}

// MARK: - Command registry

let kCommands: [Command] = buildRegistry()

func buildRegistry() -> [Command] {
    var c = [Command]()

    // ---- Reader control ------------------------------------------------
    c.append(Command(id: "init", title: "Init / Unlock handshake", category: .control,
        detail: "CLASS 0x9A + magic 5A A5 54 69 61 6E (\"Z¥Tian\"). Send first; reply sign bit = status.",
        params: []) { _ in [0xFF,0x00,0x9A, 0x5A,0xA5,0x54,0x69,0x61,0x6E] })

    c.append(Command(id: "ctrl68", title: "Reader control A (0x68)", category: .control,
        detail: "CLASS 0x68. Sent at startup (field/mode). Role inferred.",
        params: [CmdParam(name:"arg", kind:.byte, defaultValue:"")]) { a in
            var p:[UInt8]=[0xFF,0x00,0x68]; if !a[0].isEmpty { p.append(parseByte(a[0])) }; return p })

    c.append(Command(id: "ctrl69", title: "Reader control B (0x69)", category: .control,
        detail: "CLASS 0x69. Paired with 0x68 at startup. Role inferred.",
        params: [CmdParam(name:"arg", kind:.byte, defaultValue:"")]) { a in
            var p:[UInt8]=[0xFF,0x00,0x69]; if !a[0].isEmpty { p.append(parseByte(a[0])) }; return p })

    c.append(Command(id: "toggle6A", title: "Toggle (0x6A)", category: .control,
        detail: "CLASS 0x6A body 01 — buzzer/LED/field toggle. Role inferred.",
        params: [CmdParam(name:"on", kind:.byte, defaultValue:"01")]) { a in [0xFF,0x00,0x6A, parseByte(a[0])] })

    c.append(Command(id: "slot6B", title: "Device / slot select (0x6B)", category: .control,
        detail: "CLASS 0x6B body 30 or 31 — selects device/antenna. Role inferred.",
        params: [CmdParam(name:"slot", kind:.byte, defaultValue:"30")]) { a in [0xFF,0x00,0x6B, parseByte(a[0])] })

    // ---- 13.56 MHz detect ---------------------------------------------
    c.append(Command(id: "req12", title: "Request / detect (OP 0x12)", category: .detect,
        detail: "Transceive 0x66, OP 0x12 — REQA/detect. Reply → UID / ATQA / SAK.",
        params: [CmdParam(name:"A", kind:.u32le, defaultValue:"125000"),
                 CmdParam(name:"B", kind:.u32le, defaultValue:"0")]) { a in
            transceive(op:0x12, a:parseU32(a[0]), b:parseU32(a[1])) })

    c.append(Command(id: "sel13", title: "Select / read number (OP 0x13)", category: .detect,
        detail: "Transceive 0x66, OP 0x13 — anticollision/select, returns card number.",
        params: [CmdParam(name:"A", kind:.u32le, defaultValue:"125000"),
                 CmdParam(name:"B", kind:.u32le, defaultValue:"0")]) { a in
            transceive(op:0x13, a:parseU32(a[0]), b:parseU32(a[1])) })

    c.append(Command(id: "ver1f", title: "Get version / info (OP 0x1F)", category: .detect,
        detail: "Transceive 0x66, OP 0x1F — GET_VERSION / card info.",
        params: [CmdParam(name:"A", kind:.u32le, defaultValue:"125000"),
                 CmdParam(name:"B", kind:.u32le, defaultValue:"0")]) { a in
            transceive(op:0x1F, a:parseU32(a[0]), b:parseU32(a[1])) })

    // ---- Mifare Classic ------------------------------------------------
    for (op,title,note) in [
        (UInt8(0x32),"Mifare read (OP 0x32)","A carries key material (default 125000=48 E8 01 00); B = block."),
        (UInt8(0x33),"Mifare write (OP 0x33)","B = block address; data via A/B per unit."),
        (UInt8(0x34),"Mifare auth/key (OP 0x34)","Authenticate / write key for the sector."),
        (UInt8(0x21),"Read variant (OP 0x21)","Paired read op."),
        (UInt8(0x22),"Write variant (OP 0x22)","Paired write op."),
        (UInt8(0x42),"Read block → UID/data (OP 0x42)","Reply carries UID at payload[6..]."),
        (UInt8(0x43),"Block/sector op (OP 0x43)",""),
        (UInt8(0x44),"Block/sector op (OP 0x44)",""),
        (UInt8(0x41),"Block/sector op (OP 0x41)",""),
        (UInt8(0x40),"Data exchange (OP 0x40)","Long buffer; block read-back."),
        (UInt8(0x47),"Status / select (OP 0x47)",""),
    ] {
        c.append(Command(id: "mf\(String(op,radix:16))", title: title, category: .mifare,
            detail: "Transceive 0x66, OP 0x\(String(op,radix:16)). \(note)",
            params: [CmdParam(name:"A (key/aux u32)", kind:.u32le, defaultValue:"125000"),
                     CmdParam(name:"B (block/data u32)", kind:.u32le, defaultValue:"0")]) { a in
                transceive(op:op, a:parseU32(a[0]), b:parseU32(a[1])) })
    }

    // ---- Magic cards ---------------------------------------------------
    for (op,title) in [
        (UInt8(0x3F),"Key/attack helper (OP 0x3F)"),
        (UInt8(0x4F),"Key/attack helper (OP 0x4F)"),
        (UInt8(0x46),"Paged op (OP 0x46)"),
    ] {
        c.append(Command(id: "mg\(String(op,radix:16))", title: title, category: .magic,
            detail: "Transceive 0x66, OP 0x\(String(op,radix:16)). Used by UID/CUID/FUID/GTU/GDM write & key paths.",
            params: [CmdParam(name:"A", kind:.u32le, defaultValue:"125000"),
                     CmdParam(name:"B", kind:.u32le, defaultValue:"0")]) { a in
                transceive(op:op, a:parseU32(a[0]), b:parseU32(a[1])) })
    }

    // ---- MFRC522 / config ---------------------------------------------
    c.append(Command(id:"cfg85", title:"RC522 config (CLASS 0x85)", category:.config,
        detail:"CLASS 0x85 + sub (12/32/33/34). Programs MFRC522 RF registers (RxThreshold 0x18, RFCfg 0x26, ModWidth 0x24, GsNOff 0x23, GsNOn 0x27, CWGsP 0x28, ModGsP 0x29).",
        params:[CmdParam(name:"sub", kind:.byte, defaultValue:"12"),
                CmdParam(name:"extra (hex)", kind:.hexBlob, defaultValue:"")]) { a in
            var p:[UInt8]=[0xFF,0x00,0x85, parseByte(a[0])]; p += parseHexBlob(a[1]); return p })

    // ---- NTAG ----------------------------------------------------------
    c.append(Command(id:"ntagRead", title:"NTAG read page (OP 0x42/0x1F)", category:.ntag,
        detail:"NTAG pages are read through the 0x66 transceive engine. Set B = page address.",
        params:[CmdParam(name:"page", kind:.u32le, defaultValue:"0")]) { a in
            transceive(op:0x42, a:125000, b:parseU32(a[0])) })
    c.append(Command(id:"ntagD4", title:"NTAG/raw passthrough (CLASS 0xD4)", category:.ntag,
        detail:"Seen once as FF 00 .. D4 …. Low confidence; use Raw to experiment.",
        params:[CmdParam(name:"body (hex)", kind:.hexBlob, defaultValue:"D4")]) { a in
            var p:[UInt8]=[0xFF,0x00]; p += parseHexBlob(a[0]); return p })

    // ---- Advanced / hidden --------------------------------------------
    // These mirror hidden dev buttons (Init/Erase/GetVersion/RF Config/firmware). Opcodes for
    // firmware flash are not fully mapped — exposed as Raw so you can probe safely.
    c.append(Command(id:"advGetVer", title:"Get Version (hidden dev)", category:.advanced,
        detail:"Hidden 'Get Version' button. Tries transceive OP 0x1F. Confirm reply on hardware.",
        params:[]) { _ in transceive(op:0x1F, a:0, b:0) })

    // ---- Raw -----------------------------------------------------------
    c.append(Command(id:"raw", title:"Raw payload (FF 00 …)", category:.raw,
        detail:"Type the full payload in hex. The app prepends framing + checksum automatically. Payloads normally begin FF 00 <CLASS>.",
        params:[CmdParam(name:"payload hex", kind:.hexBlob, defaultValue:"FF 00 9A 5A A5 54 69 61 6E")]) { a in
            parseHexBlob(a[0]) })

    c.append(Command(id:"rawFrame", title:"Raw full frame (no framing added)", category:.raw,
        detail:"Type all 64 bytes exactly as sent; the app sends them verbatim. For replaying captures.",
        params:[CmdParam(name:"frame hex (≤64B)", kind:.hexBlob, defaultValue:"01 09 00 00 FF 00 9A 5A A5 54 69 61 6E")]) { a in
            parseHexBlob(a[0]) })   // handled specially (sent verbatim) by the view controller

    return c
}

// MARK: - Response parsing (best-effort; raw hex always shown too)

struct ParsedResponse {
    var status: String = ""     // human summary
    var length: String = ""     // payload length
    var payloadHex: String = "" // data bytes (hex)
    var ascii: String = ""      // data bytes as ASCII
    var uid: String = ""        // when the payload looks like a card UID
    var note: String = ""
}

func asciiOf(_ bytes: [UInt8]) -> String {
    bytes.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "·" }.joined()
}

func parseResponse(_ report: [UInt8]) -> ParsedResponse {
    var r = ParsedResponse()
    guard let (payload, ok, stx, status) = Frame.parse(report) else {
        r.status = "No valid frame (expected 02…FD)"; return r
    }
    r.note = ok ? "CRC ok" : "CRC?"
    r.length = "\(payload.count)"
    r.payloadHex = payload.isEmpty ? "—" : hex(payload)
    r.ascii = payload.isEmpty ? "—" : asciiOf(payload)
    let kind = stx == 0x02 ? "response" : "request"
    r.status = String(format: "%@  status=0x%02X  len=%d  (%@)", kind, Int(status), payload.count, r.note)
    // LF EM4100 read reply: payload = [05, id0..id4] (6 bytes).
    if payload.count == 6 && payload[0] == 0x05 {
        r.uid = hex(Array(payload[1..<6]))
        r.status += "  EM4100 ID"
        return r
    }
    // Heuristic HF UID: a short all-binary payload of 4/7/10 bytes.
    let printable = payload.filter { (0x20...0x7e).contains($0) }.count
    if (payload.count == 4 || payload.count == 7 || payload.count == 10) && printable < payload.count {
        r.uid = hex(payload)
    }
    return r
}
