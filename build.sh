#!/bin/bash
# Build wCopyTool.app from the Swift sources with swiftc (no Xcode project needed).
# Works on macOS 10.14 Mojave (Intel) and modern macOS (Apple Silicon).
set -euo pipefail
cd "$(dirname "$0")"

APP="wCopyTool"
BUNDLE="build/${APP}.app"
MACOS_DIR="${BUNDLE}/Contents/MacOS"
BIN="${MACOS_DIR}/${APP}"

echo "==> cleaning"
rm -rf build
mkdir -p "${MACOS_DIR}" "${BUNDLE}/Contents/Resources"

SRCS=(Sources/Protocol.swift Sources/HIDTransport.swift Sources/AppDelegate.swift Sources/main.swift)

# Minimum macOS the binary must run on (your Mojave Intel Mac). Override with env if needed.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}"
echo "==> deployment target: ${MACOSX_DEPLOYMENT_TARGET}"

# Pick archs: try universal, fall back to native (Mojave has no arm64 slice).
ARCHS=()
if swiftc -target arm64-apple-macosx10.14 -e "" >/dev/null 2>&1; then :; fi
HOST_ARCH="$(uname -m)"
if [ "${HOST_ARCH}" = "arm64" ]; then
  ARCH_FLAGS=(-arch arm64 -arch x86_64)   # universal on Apple Silicon
else
  ARCH_FLAGS=(-arch x86_64)               # Intel / Mojave
fi

echo "==> compiling (${ARCH_FLAGS[*]})"
if ! swiftc -O "${ARCH_FLAGS[@]}" \
      -framework Cocoa -framework IOKit \
      -o "${BIN}" "${SRCS[@]}" ; then
  echo "==> universal build failed, retrying native-only"
  swiftc -O -framework Cocoa -framework IOKit -o "${BIN}" "${SRCS[@]}"
fi

echo "==> writing Info.plist"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper/TCC treat it as a stable app identity (optional but helps HID perms).
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${BUNDLE}" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> done: ${BUNDLE}"
echo "    run:  open ${BUNDLE}     (or: ${BIN})"
