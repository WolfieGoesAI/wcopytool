# wCopyTool — macOS console for the nsccn "wCopy" / nfcPro RFID/NFC copier

A native AppKit + IOKit app that talks to the same USB-HID copier driven on Windows by
`nfcPro_x64.exe`. It exposes **every command found in the Windows app — visible and hidden —
as an invocable button**, shows the exact framed bytes before sending, and parses the reply
into labelled fields (Status / UID / ATQA / SAK / ATS / Version) with a full TX/RX hex log.

This is an independent interoperability tool for hardware you own. It does **not** contact
nsccn's servers and does not include the online key-cracking calls the Windows app makes.

## Build & run

Requires the macOS command-line Swift toolchain (Xcode or the Command Line Tools). No Xcode
project needed.

```
./build.sh
open build/wCopyTool.app
```

- On **Apple Silicon** it builds a universal (arm64 + x86_64) binary.
- On your **Mojave (10.14) Intel** Mac it builds x86_64 and avoids every 10.15+ API.
- If first launch is blocked by Gatekeeper: right-click the app → Open, or
  `xattr -dr com.apple.quarantine build/wCopyTool.app`.
- If reports don't arrive, flip **"Prepend report-ID byte"** (top-right) — it covers units
  whose HID report is numbered vs unnumbered.

## Prebuilt via GitHub Actions

`.github/workflows/build.yml` builds the app on a macОS runner so you don't have to compile
locally:

- **Every push** (to `main`/`master`) and manual **Run workflow** produces a downloadable
  artifact `wCopyTool-macos` → `wCopyTool-macos.zip` under the run's *Artifacts*.
- **Tag a release** (`git tag v1.0 && git push --tags`) and the same zip is attached to a
  GitHub **Release** as a permanent download link.
- The runner is Apple Silicon, so the binary is **universal (arm64 + x86_64)** and runs on both
  your M1 and the Mojave Intel Mac (deployment target 10.14).

Artifacts/Release downloads arrive quarantined; on first launch right-click → Open, or
`xattr -dr com.apple.quarantine wCopyTool.app`. The build is ad-hoc signed (no paid Apple
Developer ID needed for personal use).

## Using it

1. Plug in the copier. The status bar turns green with `VID:PID  product  SN:…` when matched
   (VIDs `0416`/`2518`). Hit **Rescan** if you hotplug.
2. The window has tabs that mirror the Windows app:
   - **Card (13.56)** — Init/unlock, detect, read number, get version, and the write ops
     (MF1 / CUID·FUID / GTU / GDM) as opcode-labelled buttons.
   - **Sectors (Mifare)** — key A/B, S50/S70, block address, Auth / Read / Write block, dump all.
   - **NTAG** — page read/write, read-all, CFG pages.
   - **125 kHz ID** — experimental LF sends to help discover that path.
   - **Config (RC522)** — the MFRC522 register values (with defaults) → write via class 0x85.
   - **Advanced** — hidden control opcodes (toggle, slot select, attack helpers).
   - **Raw** — send any payload (auto-framed) or a verbatim 64-byte frame to replay captures.
3. Every button sends immediately; the result lands in the shared **Parsed response** fields
   (UID / ATQA / SAK / ATS / Version / Status), the **raw hex** pane, and the timestamped log.
4. Start with **Card ▸ Init / Unlock** — the Windows app sends this handshake first.

Each button's label carries the confirmed opcode; the action names are the best match to the
Windows buttons. The exact argument layout inside the `0x66` transceive envelope is still being
confirmed on hardware, so treat the write/sector buttons as test frames and watch the replies.

### Finishing the map on hardware
The transport, framing, checksum, device IDs, command classes and opcodes are recovered
exactly from the binary. What's left to pin down is the per-opcode *argument* semantics inside
the `0x66` transceive envelope (which of A/B is address vs count vs key). The **Raw** category
lets you send any payload or replay a full 64-byte capture, so you can resolve those live — send
a read of a known block, watch the reply, adjust. See `docs/COMMANDS.md` for the complete map.

## Files
```
build.sh                 one-shot swiftc build → build/wCopyTool.app
Info.plist               bundle metadata (LSMinimumSystemVersion 10.14)
Sources/Protocol.swift   framing, checksum, command registry, response parser
Sources/HIDTransport.swift  IOHIDManager open/match/read/write
Sources/AppDelegate.swift   AppKit UI (command tree, params, fields, log)
Sources/main.swift          entry point + menus
docs/COMMANDS.md         full reverse-engineered protocol & command/button map
```

## Safety note
The hidden developer buttons in the Windows app include firmware **Init / Erase / flash**
(`X7V310…-74H`) whose opcodes are **not** fully mapped. wCopyTool deliberately does not guess
those; use the Raw sender only if you know what a given frame does — a wrong firmware opcode can
brick the reader.
