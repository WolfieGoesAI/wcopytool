#!/bin/bash
# Build wCopyTool.app with swiftc (no Xcode project).
#   - Each architecture is compiled with an EXPLICIT target triple so the Mach-O
#     minimum-OS load command is stamped correctly (this is what makes the x86_64
#     slice actually run on macOS 10.14 Mojave).
#   - On Apple Silicon it produces a universal (arm64 + x86_64) binary.
#   - Set MOJAVE_ONLY=1 to force a single x86_64 / 10.14 slice (runs on Mojave, and
#     on Apple Silicon via Rosetta) — the safest build for the Intel Mojave Mac.
set -euo pipefail
cd "$(dirname "$0")"

APP="wCopyTool"
BUNDLE="build/${APP}.app"
MACOS_DIR="${BUNDLE}/Contents/MacOS"
BIN="${MACOS_DIR}/${APP}"

SRCS=(Sources/Protocol.swift Sources/HIDTransport.swift Sources/AppDelegate.swift Sources/main.swift)
COMMON=(-O -framework Cocoa -framework IOKit)

# macOS floor for the Intel slice. arm64 macOS cannot go below 11.0, so that slice
# uses 11.0 — Mojave ignores it and loads the x86_64 slice.
X86_TRIPLE="x86_64-apple-macosx10.14"
ARM_TRIPLE="arm64-apple-macosx11.0"

echo "==> cleaning"
rm -rf build
mkdir -p "${MACOS_DIR}" "${BUNDLE}/Contents/Resources"

HOST_ARCH="$(uname -m)"
want_arm=0; want_x86=1
if [ "${MOJAVE_ONLY:-0}" = "1" ]; then
  want_arm=0; want_x86=1
elif [ "${HOST_ARCH}" = "arm64" ]; then
  want_arm=1; want_x86=1          # universal on Apple Silicon
else
  want_arm=0; want_x86=1          # Intel host → x86_64 only
fi

THIN=()
if [ "${want_x86}" = "1" ]; then
  echo "==> compiling x86_64 (${X86_TRIPLE})"
  swiftc "${COMMON[@]}" -target "${X86_TRIPLE}" -o "build/${APP}.x86_64" "${SRCS[@]}"
  THIN+=("build/${APP}.x86_64")
fi
if [ "${want_arm}" = "1" ]; then
  echo "==> compiling arm64 (${ARM_TRIPLE})"
  if swiftc "${COMMON[@]}" -target "${ARM_TRIPLE}" -o "build/${APP}.arm64" "${SRCS[@]}"; then
    THIN+=("build/${APP}.arm64")
  else
    echo "   (arm64 slice failed; shipping x86_64 only)"
  fi
fi

echo "==> assembling ${BIN}"
if [ "${#THIN[@]}" -gt 1 ]; then
  lipo -create "${THIN[@]}" -output "${BIN}"
else
  cp "${THIN[0]}" "${BIN}"
fi
rm -f build/${APP}.x86_64 build/${APP}.arm64

cp Info.plist "${BUNDLE}/Contents/Info.plist"

# App icon. Prefer a canonical iconutil-built .icns (macOS); fall back to the committed one.
ICNS=""
if command -v iconutil >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if python3 -I icon/make_icon.py --iconset >/dev/null 2>&1 && [ -d build/AppIcon.iconset ]; then
    if iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns 2>/dev/null; then
      ICNS="build/AppIcon.icns"
      echo "==> icon built with iconutil"
    fi
  fi
fi
if [ -z "${ICNS}" ] && [ -f Resources/AppIcon.icns ]; then
  ICNS="Resources/AppIcon.icns"
fi
if [ -n "${ICNS}" ]; then
  cp "${ICNS}" "${BUNDLE}/Contents/Resources/AppIcon.icns"
  echo "==> icon installed (${ICNS})"
fi

# Show the stamped minimum-OS per slice (visible in the CI log for verification).
if command -v otool >/dev/null 2>&1; then
  echo "==> Mach-O minimum OS per slice:"
  otool -l "${BIN}" | awk '/cmd LC_BUILD_VERSION|cmd LC_VERSION_MIN_MACOSX/{f=1} f&&/platform|minos|version/{print} /^Load command/{if(f>1)f=0; if(f)f++}' | head -20 || true
  lipo -info "${BIN}" || true
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${BUNDLE}" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> done: ${BUNDLE}"
echo "    run:  open ${BUNDLE}"
