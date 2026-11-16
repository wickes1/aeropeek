#!/usr/bin/env bash
# Builds build/AeroPeek.app, signed with the "aeropeek Dev" identity.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also replace ~/Applications/AeroPeek.app and relaunch it
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="aeropeek Dev"
# Never sign ad-hoc: an ad-hoc code identity changes on every build, and macOS would then drop the
# Accessibility and Screen Recording grants after each rebuild.
# grep reads to the end (no -q): under pipefail an early exit would fail the pipeline through SIGPIPE.
if ! security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" >/dev/null; then
  echo "no \"$IDENTITY\" signing identity: run scripts/make-signing-cert.sh first" >&2
  exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/AeroPeek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/AeroPeek" "$APP/Contents/MacOS/AeroPeek"
mkdir -p "$APP/Contents/Resources"
# Generated from Resources/AppIcon.svg by scripts/make-icon.sh; committed so a build needs neither rsvg-convert nor iconutil.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/AeroPeek.app"
  pkill -x AeroPeek || true
  # SIGTERM ends it asynchronously; a second copy would draw a second panel.
  for _ in $(seq 50); do pgrep -x AeroPeek >/dev/null || break; sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "installed $DEST"
fi
