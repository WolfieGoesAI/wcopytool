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

func u32be(_ v: UInt32) -> [UInt8] { [UInt8((v>>24)&0xFF), UInt8((v>>16)&0xFF), UInt8((v>>8)&0xFF), UInt8(v&0xFF)] }

// LF write ops on class 0x66 (both confirmed from the Write-ID handler):
let kOpT5577: UInt8 = 0x13   // T5577 block write  (20-byte frame)
let kOpEM4305: UInt8 = 0x12  // EM4305 word write  (16-byte frame)

/// LF word/block write. op 0x13 = T5577 (sends the 20-byte frame), op 0x12 = EM4305 (16-byte).
///   FF 00 66 00 1E <freq:u32 LE> <op> 00 <addr> <word:u32 BE> [00 00 00 00 for T5577]
func lfWriteWord(op: UInt8, addr: UInt8, word: UInt32, freq: UInt32 = 125000) -> [UInt8] {
    var p: [UInt8] = [0xFF, 0x00, 0x66, 0x00, 0x1E] + u32le(freq) + [op, 0x00, addr]
    p += u32be(word)
    if op == kOpT5577 { p += [0x00, 0x00, 0x00, 0x00] }
    return p
}
// Back-compat helper used by the verified T5577 path.
func lfWriteBlock(block: UInt8, word: UInt32, freq: UInt32 = 125000) -> [UInt8] {
    lfWriteWord(op: kOpT5577, addr: block, word: word, freq: freq)
}

// Native EM4305 (class 0x66, confirmed from the handler):
//   login:      FF 00 66 00 1E <freq:u32 LE> 21 <password:u32 LE>          (op 0x21)
//   write word: FF 00 66 00 1E <freq:u32 LE> 22 <addr> <word: 4 bytes>     (op 0x22)
// EM4100 emulation writes word 4 = config (wire FA 01 A8 00), words 5 & 6 = EM data.
func em4305Login(pwd: UInt32, freq: UInt32 = 125000) -> [UInt8] {
    [0xFF, 0x00, 0x66, 0x00, 0x1E] + u32le(freq) + [0x21] + u32le(pwd)
}
func em4305WriteWord(addr: UInt8, bytes: [UInt8], freq: UInt32 = 125000) -> [UInt8] {
    [0xFF, 0x00, 0x66, 0x00, 0x1E] + u32le(freq) + [0x22, addr] + Array(bytes.prefix(4))
}
let kEM4305ConfigWire: [UInt8] = [0xFA, 0x01, 0xA8, 0x00]   // word 4 config for EM4100 (from app)

/// Standard EM4100 encoder: 40-bit id → 64-bit frame → (block1, block2) words.
/// 9 header ones, 10×(4 data bits + even row parity), 4 column-parity bits, 1 stop bit (0).
func em4100Words(_ id40: UInt64) -> (UInt32, UInt32) {
    var bits = [Int]()
    bits += Array(repeating: 1, count: 9)
    var col = [0,0,0,0]
    for n in 0..<10 {
        let shift = (9 - n) * 4
        let nib = Int((id40 >> UInt64(shift)) & 0xF)
        var row = 0
        for b in 0..<4 {
            let bit = (nib >> (3 - b)) & 1
            bits.append(bit); row ^= bit; col[b] ^= bit
        }
        bits.append(row)            // even row parity
    }
    for b in 0..<4 { bits.append(col[b]) }   // even column parity
    bits.append(0)                           // stop bit
    // pack MSB-first into two 32-bit words
    func pack(_ r: Range<Int>) -> UInt32 {
        var w: UInt32 = 0
        for i in r { w = (w << 1) | UInt32(bits[i]) }
        return w
    }
    return (pack(0..<32), pack(32..<64))
}

// Proxmark3 T55xx default-password dictionary (wire-order hex) + this reader's own keys,
// curated: bit-inverse duplicates removed (the normal/reverse routine covers the mirror forms).
let kLFKeyDict: [String] = [
    "00000000","51243648","000D8787","19920427","002BCFCF","50524F58","F9DCEBA0","65857569",
    "89A69E60","314159E0","7B3D5C48","AA55BBBB","A5B4C3D2","1C0B5848","00434343","50415353",
    "444E4752","4E457854","44B44CAE","88661858","E9920427","575F4F4B","50520901","20206666",
    "5469616E","576F6C66","C0F5009A","07CEE75D","FEEDBEEF","DEADC0DE","A9EF2AFC","11111111","22222222",
    "33333333","55555555","66666666","77777777","99999999","BBBBBBBB","FFFFFFFF","A0A1A2A3",
    "B0B1B2B3","01234567","12345678","0CB7E7FC","FABADA11","AABBCCDD","0C0D0E0F","01020304",
]

/// 4-byte big-endian pad of a hex password/word string (wire order, MSB first).
func pad4(_ bytes: [UInt8]) -> [UInt8] {
    var b = Array(bytes.prefix(4))
    while b.count < 4 { b.append(0) }
    return b
}
func keyBytes(_ hex: String) -> [UInt8] { pad4(parseHexBlob(hex)) }
func rev4(_ b: [UInt8]) -> [UInt8] { Array(pad4(b).reversed()) }
/// Bit-mirror all 32 bits (T5577 ↔ EM4305 clock the password in opposite bit order).
func bitrev4(_ b: [UInt8]) -> [UInt8] {
    let p = pad4(b)
    var v: UInt32 = (UInt32(p[0])<<24)|(UInt32(p[1])<<16)|(UInt32(p[2])<<8)|UInt32(p[3])
    var r: UInt32 = 0
    for _ in 0..<32 { r = (r<<1)|(v&1); v >>= 1 }
    return [UInt8((r>>24)&0xFF),UInt8((r>>16)&0xFF),UInt8((r>>8)&0xFF),UInt8(r&0xFF)]
}
/// Candidate forms of a key for a sweep: as-is and byte-reversed (normal/reverse routine).
func keyForms(_ hex: String) -> [(String,[UInt8])] {
    let b = keyBytes(hex)
    var out: [(String,[UInt8])] = []
    func add(_ tag: String, _ v: [UInt8]) { if !out.contains(where: {$0.1 == v}) { out.append((tag, v)) } }
    add("", b); add("~rev", rev4(b))
    return out
}

/// Password-read attempt: EM read with a key placed in the trailing field (for T5577 unlock sweeps).
func lfReadPwd(pwd: [UInt8], freq: UInt32 = 125000) -> [UInt8] {
    [0xFF,0x00,0x65,0x05,0x1E] + u32le(freq) + pad4(pwd)
}

// Password-aware LF write helpers (byte-array form avoids endianness confusion).
//   T5577 block write WITH password (op 0x13): data word + password word.
func lfT5Write(addr: UInt8, word: [UInt8], pwd: [UInt8], freq: UInt32 = 125000) -> [UInt8] {
    lfT5WriteMode(addr: addr, word: word, pwd: pwd, freq: freq, mode: 0x00)
}
//   T5577 block write WITHOUT password (op 0x12): 16-byte frame, no trailing password.
//   The original app issues op 0x12 then op 0x13 for every block (covers unprotected + protected).
func lfT5WriteNoPwd(addr: UInt8, word: [UInt8], freq: UInt32 = 125000) -> [UInt8] {
    [0xFF,0x00,0x66,0x00,0x1E] + u32le(freq) + [0x12,0x00,addr] + pad4(word)
}
//   LF mode/field control (op 0x00): the app brackets LF ops with 00 <sub> 00 00 (sub 0x14 before
//   writes, 0x05 before reads).
func lfModeCmd(_ sub: UInt8, freq: UInt32 = 125000) -> [UInt8] {
    [0xFF,0x00,0x66,0x00,0x1E] + u32le(freq) + [0x00, sub, 0x00, 0x00]
}
//   RF front-end config (op 0x1F) exactly as the original app sends it.
func lfRFConfig(freq: UInt32 = 125000) -> [UInt8] {
    [0xFF,0x00,0x66,0x00,0x1E] + u32le(freq) + [0x1F,0x18,0x01,0xEF,0x00,0x9B,0x00,0x86,0x01]
}
// T5577 EM4100 config written by the original app (block 0) — note 0x50, not 0x40.
let kT5ConfigWire: [UInt8] = [0x00,0x14,0x80,0x50]
// Default write password the original app sets on every card: "Tian" (ASCII 54 69 61 6E).
let kT5DefaultPwdHex = "5469616E"
// Old passwords the app authenticates with to force the password to a known value (block 7).
let kT5NormalizeKeys = ["C0F5009A","00000000","19920427","1C0B5848","5469616E"]
// EM4305 login passwords the app tries before setting word2 = "Tian" (wire bytes from the capture:
// 00000000 and 05 d7 3b 9f = LE of 0x9F3BD705).
let kEM4305NormalizeKeys = ["00000000","05D73B9F"]
//   T5577 block write with an explicit mode/flag byte (the byte between op 0x13 and the block
//   number — always 0x00 in normal writes). Used by the test-mode unbrick to probe whether the
//   firmware exposes Proxmark-style test mode / downlink waveforms (r0..r3) for block-0 recovery.
func lfT5WriteMode(addr: UInt8, word: [UInt8], pwd: [UInt8], freq: UInt32 = 125000, mode: UInt8) -> [UInt8] {
    [0xFF,0x00,0x66,0x00,0x1E] + u32le(freq) + [0x13,mode,addr] + pad4(word) + pad4(pwd)
}
// Proxmark T5577 unbrick/reset config written to block 0 in test mode (lf t55 write -b 0 -d 000880E0 -t).
// A safe, readable default modulation that revives a card whose block 0 got corrupted.
let kT5UnbrickConfig: UInt32 = 0x000880E0
// Passwords the working Proxmark unbrick script writes block 0 with, in password mode (-p):
// "Tian", a date key, zero, and "Wolf". One of these is the card's write password.
let kT5UnbrickPwds: [String] = ["5469616E", "19920427", "00000000", "576F6C66"]
//   EM4305 login (op 0x21) with a given password.
func em4305LoginBytes(pwd: [UInt8], freq: UInt32 = 125000) -> [UInt8] {
    [0xFF,0x00,0x66,0x00,0x1E] + u32le(freq) + [0x21] + pad4(pwd)
}

// T5577 HID-prox FSK config (block 0), wire order (= 0x00107060).
let kT5HIDConfigWire: [UInt8] = [0x00,0x10,0x70,0x60]

func parseU40(_ s: String) -> UInt64 {
    let t = s.trimmingCharacters(in: .whitespaces)
    let v: UInt64
    if t.lowercased().hasPrefix("0x") { v = UInt64(t.dropFirst(2), radix: 16) ?? 0 }
    else { v = UInt64(t) ?? 0 }
    return v & 0xFF_FFFF_FFFF
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
        let id = Array(payload[1..<6])
        r.uid = hex(id)
        let v40 = id.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let v32 = v40 & 0xFFFF_FFFF
        let hex10 = id.map { String(format: "%02X", $0) }.joined()
        r.ascii = String(format: "EM4100  hex10=%@  dec=%llu  (cust=%02X)", hex10, v32, Int(id[0]))
        r.status = "EM4100 read OK"
        return r
    }
    // Heuristic HF UID: a short all-binary payload of 4/7/10 bytes.
    let printable = payload.filter { (0x20...0x7e).contains($0) }.count
    if (payload.count == 4 || payload.count == 7 || payload.count == 10) && printable < payload.count {
        r.uid = hex(payload)
    }
    return r
}
