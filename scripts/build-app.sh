#!/usr/bin/env bash
# Builds build/Drift.app from source.
#
#   ./scripts/build-app.sh            release build for this Mac
#   ./scripts/build-app.sh --universal  Apple silicon + Intel (needs full Xcode)
#
# Works with either Xcode or the free Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Drift.app"
ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "› Compiling…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "› Assembling Drift.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Drift" "$APP/Contents/MacOS/Drift"
cp packaging/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${GITHUB_SHA:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"
fi

iconutil -c icns packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "› Signing (ad-hoc, sandboxed, hardened runtime)…"
codesign --force --sign - \
  --options runtime \
  --entitlements packaging/Drift.entitlements \
  --timestamp=none \
  "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $ROOT/$APP"
