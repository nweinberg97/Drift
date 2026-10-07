#!/usr/bin/env bash
# Drift installer — builds from source on your Mac and installs to /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/nweinberg97/Drift/main/scripts/install.sh | bash
#
# Why build from source? Apps you compile yourself aren't quarantined, so macOS
# opens Drift without the "unidentified developer" warning — no paid Apple
# account needed, and you're running exactly the code in the repository.
set -euo pipefail

REPO="https://github.com/nweinberg97/Drift.git"
DEST="/Applications/Drift.app"

say() { printf "\033[1m›\033[0m %s\n" "$1"; }

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Drift is a macOS app." >&2; exit 1
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 13 )); then
  echo "Drift needs macOS 13 Ventura or newer." >&2; exit 1
fi

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  say "Drift needs Apple's free Command Line Tools to build."
  say "A macOS window will open — click Install, wait for it to finish, then run this command again."
  xcode-select --install || true
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -f "./Package.swift" ]] && grep -q 'name: "Drift"' ./Package.swift; then
  say "Building from this folder…"
  SRC="$(pwd)"
else
  say "Downloading source…"
  git clone --depth 1 --quiet "$REPO" "$WORK/Drift"
  SRC="$WORK/Drift"
fi

say "Building (a minute or two the first time)…"
LOG="$WORK/build.log"
if ! (cd "$SRC" && ./scripts/build-app.sh) >"$LOG" 2>&1; then
  echo
  echo "Build failed. Last lines of the log:" >&2
  grep -v "could not determine XCTest paths\|unable to lookup item 'PlatformPath'" "$LOG" | tail -40 >&2
  echo >&2
  echo "Your setup: macOS $(sw_vers -productVersion), $(swift --version 2>/dev/null | head -1)" >&2
  echo "Please share the lines above so it can be fixed." >&2
  exit 1
fi

say "Installing to /Applications…"
if pgrep -x Drift >/dev/null 2>&1; then
  osascript -e 'tell application id "com.nweinberg.drift" to quit' >/dev/null 2>&1 || pkill -x Drift || true
  sleep 1
fi
if [[ -w /Applications ]]; then
  rm -rf "$DEST"
  ditto "$SRC/build/Drift.app" "$DEST"
else
  sudo rm -rf "$DEST"
  sudo ditto "$SRC/build/Drift.app" "$DEST"
fi

say "Launching Drift…"
open "$DEST"
printf "\n\033[1mDrift is running.\033[0m Look top-left of your screen and in the menu bar.\n"
printf "Press ⌥⌘T anywhere to start a timer.\n"
