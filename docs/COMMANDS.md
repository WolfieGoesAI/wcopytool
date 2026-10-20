# wCopy / nfcPro HID protocol & command map

Reverse-engineered from `nfcPro_x64.exe` (nsccn.com, build `2025.03.11.01`, MSVC2019/MFC,
internal name `nfcCopy`). This is the device-facing protocol used by the **nsccn "wCopy"**
family of RFID/NFC copiers (NSR106 / NSR122 / WBW106 / NFC108 / NSR102 / NSR121, firmware
"NFC V5.3–V5.5"). The 13.56 MHz front-end is an **MFRC522** (confirmed by the register names
in the hidden Config panel). Confidence levels are marked per item.

---

## 1. Transport  (confirmed)

| Property | Value |
|---|---|
| Interface | USB **HID** (hidapi statically linked) |
| Report size | **64 bytes** in and out |
| Read timeout | 2000 ms |
| Report ID | 0 (unnumbered) |

Device is matched by VID:PID, first match wins:

| VID | PID | Note |
|---|---|---|
| `0x0416` | `0xB030` | Winbond/Nuvoton HID MCU |
| `0x0416` | `0xB031` | |
| `0x2518` | `0x6022` | |
| `0x2518` | `0x6018` | |

---

## 2. Frame format  (confirmed)

A 64-byte report. Byte layout of the report *data* (report-ID byte handled by the OS):

```
off  value              meaning
0    0x01               STX (constant)
1    LEN                = (payload length) + 6   ; total framed length incl. STX..ETX
2    0x00               reserved
3    0x00               reserved
4..  payload[0..n-1]    (payload length capped at 0x30 = 48)
4+n  CHK                checksum
5+n  0xFE               ETX (constant)
...  0x00               zero padding to 64
```

- **Checksum** `CHK = (~(Σ bytes[0 .. 3+n])) & 0xFF` — one's complement of the 8-bit sum of
  `STX, LEN, 00, 00, payload…`.
- Responses use the same framing; parse by locating `0x01 … 0xFE`.

> On Windows (hidapi) the buffer additionally carries a leading `0x00` report-ID byte, so the
> on-wire write is `00 | 01 LEN 00 00 …`. On macOS IOHIDManager the report-ID is passed
> separately, so the data buffer starts at `0x01`. The app has a "prepend report-ID byte"
> toggle in case a given unit enumerates its report as *numbered*.

---

## 3. Payload structure  (confirmed)

**Every** payload begins `FF 00 <CLASS>`, optionally followed by class-specific bytes:

```
payload = FF 00 CLASS [body…]
```

### Command classes observed

| CLASS | Name | Body | Confidence |
|---|---|---|---|
| `0x9A` | **Init / unlock handshake** | `5A A5 54 69 61 6E`  (magic `Z¥` + ASCII `"Tian"`) | confirmed |
| `0x66` | **ISO14443A transceive** (13.56 MHz) | `00 1E <A:u32> <OP> <B:u32>` — see §4 | confirmed |
| `0x68` | reader control A (field/mode) | — / 1 byte | confirmed opcode, role inferred |
| `0x69` | reader control B | — / 1 byte | confirmed opcode, role inferred |
| `0x6A` | toggle (buzzer/LED/field) | `01` | confirmed opcode, role inferred |
| `0x6B` | device / slot select | `30` or `31` | confirmed opcode, role inferred |
| `0x85` | **MFRC522 register config** | `<sub: 12/32/33/34>` | confirmed opcode; MFRC522 per UI |
| `0xD4` | NTAG/raw passthrough | opcode-dependent | low (seen once) |

The init `0x9A` is sent first; the app checks the reply's sign bit for success.

---

## 4. ISO14443A transceive (CLASS 0x66) — the card engine  (confirmed structure)

Built from the template `FF 00 66 00 1E 00000000 <OP> 00000001` (14-byte payload):

```
payload off  field
0            0xFF
1            0x00
2            0x66           transceive class
3            0x00
4            0x1E           (fixed; reserved/flags)
5..8         A : uint32 LE  parameter A (timeout/aux; 125000 = 0x0001E848 seen as default)
9            OP             card sub-opcode (table below)
10..13       B : uint32 LE  parameter B (block/page address or data; from caller)
```

### Card sub-opcodes (OP at payload[9])  — grouped by the UI action that uses them

Exact per-op argument semantics (which of A/B is address vs count vs key) are best confirmed
against hardware; the app sends them and shows the reply so you can finish the mapping live.

| OP | Likely operation | Evidence |
|---|---|---|
| `0x12` | detect / request card (REQA→anticoll) | detect path |
| `0x13` | select / read card number | detect path |
| `0x1F` | read version / card info | detect path |
| `0x21` | read (variant 1) | paired with 0x22 |
| `0x22` | write (variant 1) | paired with 0x21 |
| `0x32` | Mifare read  (uses A=key material `48 E8 01 00`) | sector path |
| `0x33` | Mifare write | sector path |
| `0x34` | Mifare auth / write key | sector path |
| `0x3F` | key/attack helper | near MFCUK/Hardnested paths |
| `0x40` | data exchange (long buffer, 27-byte payload) | block read-back |
| `0x41` | block/sector op | write group |
| `0x42` | **read block → UID/data** (returns UID at reply[6..]) | handler reads reply UID bytes |
| `0x43` | block/sector op | write group |
| `0x44` | block/sector op | write group |
| `0x46` | paged op (`46 00`, `46 28`) with address | two call sites |
| `0x47` | status / select | — |
| `0x4F` | key/attack helper | paired with 0x3F |

---

## 4a. Response framing  (CONFIRMED on hardware, NSR102-IDIC / V705N3)

Replies do **not** reuse the request framing. They are:

```
02 LEN STATUS 00  <data …>  CHK  FD
```
- STX = **0x02** (requests use 0x01), ETX = **0xFD** (requests use 0xFE).
- `LEN` = total framed length (data length + 6), same convention as requests.
- `STATUS` byte (offset 2) = 0x01 on the observed OK replies.
- `CHK` = one's-complement sum, same formula.
- The data region is raw (no `FF 00 CLASS` echo).

Confirmed replies:
- `FF 00 68` → `02 1E 01 00 "wCopy NSR102-IDIC V705N3" CHK FD` → **device model + firmware**.
- `FF 00 69` → `02 12 01 00 "T39190089986" CHK FD` → **serial number**.
- `FF 00 66 00 1E … 12 …` (detect) → `02 07 01 00 00 F5 FD` → 1-byte status `00` (no card / not the
  active-poll opcode for this reader's LF side).

## 4b. 125 kHz LF channel — CLASS 0x65  (CONFIRMED on hardware)

LF is a **separate class, 0x65** (HF transceive is 0x66). From the Read-ID handler:

- **Read EM4100**: `FF 00 65 05 1E <freq:u32 LE> 00 00 00 00`  (mode `05` = read 5-byte id).
  - Reply: `02 0C 01 00 05 <5 id bytes> CHK FD`. Verified: card `00 49 96 02 D2` → `0x499602D2` = 1234567890.
  - Frequency table (Hz): 125000 (`48 E8 01 00`), 175000, 250000, 300000, 375000, 500000.

- **Write ID (T5577)** — from the Write-ID handler, the write frame is on the **0x66** channel:
  `FF 00 66 00 1E <freq:u32> 13 <p10> <p11> <dataWord:u32> <arg:u32>` (len 20, op `0x13`).
  The handler first runs the target id through an EM/T5577 **bit encoder** to produce the data
  words, then calls a read-back verify (`FF 00 66 00 1E <freq> 00 …`). Porting that encoder is
  required for a safe one-click write — not yet implemented (guessed data words risk bricking cards).

## 5. Response fields  (formats confirmed from the binary)

Replies are the same 64-byte frame. The payload after the `FF 00 CLASS` echo carries a
status/type byte then data. Known rendered formats (from the program's format strings):

- **UID**: `%2.2x %2.2x %2.2x %2.2x [%2.2x %2.2x %2.2x]` — 4/7/10-byte UID (length chosen by a
  type byte: `0x04`→4, `0x09`→7, `0x0B`→10).
- **ATQA**: 2 bytes.  **SAK**: 1 byte.
- **ATS**: up to 16 bytes (`ATS: %2.2X …`).
- **Version**: 8 bytes (`version: %2.2X ×8`) — NTAG/EV1 GET_VERSION.
- **Mifare sector**: `Sector %d`, then `Block %02d : <16 hex>` ×4, with ACL/key line.
- **NTAG page**: `Page Adr  Data  Ascii`, 4 bytes/page; special pages CC, PWD, PACK, CFG0, CFG1,
  static/dynamic lock.
- **Status**: text keyed by a result code; negative (sign bit) = failure.

---

## 6. Full UI inventory (visible + hidden) — for feature parity

From the PE dialog resources. `HID` = control exists but `WS_VISIBLE` is off (hidden/advanced).

### Main production window (dialog 132)
Device combo, **Online Upgrade**; **ID-card area**: ID number, Frequency, Read ID, Write ID;
**IC-card area**: One-click Decode, Read-only number, One-click Write, Format, Lock, Write GTU;
**Data area**: Save, Compare, Analyze, Edit, Import, Import-compare; *hidden*: `CRC`, `use keys`.

### Decode / early window (dialog 102)
Test*(hid)*, Read-only number, Start Decode, Save, Import, Standard Decode, **Brute-force**(dis),
**流星锤 "Meteor Hammer" / Nested**(key-recovery), Use keys, key **A/B**, **Format Card**,
One-click Write, **Write UID / Lock UFUID / Write MF1 / Write CUID·FUID / Write GTU / Write GDM**.

### Config & attack panel (dialog 134 / 147)
Force→SAK08, crack-sector select, **decode depth**, Use known keys, Read with history keys,
**Online compute password / Networked computing / Get Keys** (server `m1.ickezhan.com`),
Read/Set card number, Read password, S50/S70, Read/Write 亲邻 SAK88, Standard Format,
Format GTU/GDM. *Hidden attack selectors*: `A`,`B`,`MFOC`,`HARDNESTED`,`MFCUK`,`Radio4..8`,
`common prefix attack`; Monitor Card; `X7 Pro Get Sniffed Key`; `QL88`; anti-copy-firewall bypass.

### 125 kHz / band window (dialog 141)
EMID, number formats **Hex-10 / Dec-10 / Dec-8**, band **HID 125KHz / ISO14443A 13.56MHz**,
Read / Write / Load Dump, Frequency combo, Key A / Key B, T5577 note, HID format, Read Number,
Start Decode, Write Card, Format, Write GTU, Lock, Edit, Save Dump.
*Hidden developer buttons*: `Test`, **`Init`**, **`Erase`**, **`X7V310 English-74H`**,
**`X7V310中文-74H`** (firmware images), **`Get Version`**, **`RF Config`**, `Update`, `Show`.

### NTAG / CPU tabs (dialog 139) & RF register panel
Tabs Basic / Compare / Config / Advanced / About; **NTag 21x**, **CPU**(dis); Device / SN.
Hidden **MFRC522 register** fields with defaults: `RxThresholdReg(0x18)=0x84`, `RFCfgReg(0x26)=0x48`,
`ModWidthReg(0x24)=0x26`, `GsNOffReg(0x23)=0x88`, `GsNOnReg(0x27)=0x88`, `CWGsPReg(0x28)=0x20`,
`ModGsPReg(0x29)=0x20` → these are written via CLASS `0x85`.

### Language panel (dialog 158)
EN / Simplified / Traditional; hidden: Russian, German, French, Spanish, Arabic, Portuguese,
Hindi/Malay/Japanese (disabled). Text is loaded at runtime from `Language.ini`.

---

## 7. Network endpoints (not needed for local control — omit in a clean tool)
- Update: `http://www.nsccn.com/download/soft/nfc/nfcPro_x64.exe` (+ `_version.txt`, `_kgf_`, `_wcopy_`).
- Online key cracking: `…/proxy/NFCReaderTools/liftanalyze/?data=…&content=Key`,
  `…/M1/M1HelperWeb.aspx?fx=`, backed by `m1.ickezhan.com` and an Alibaba FaaS host. Clear-text HTTP.
