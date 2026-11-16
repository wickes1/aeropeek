#!/usr/bin/env bash
# Builds the distributable: a universal AeroPeek.app, zipped, plus a Homebrew cask that points at it.
#   scripts/release.sh
# Output in dist/: AeroPeek-<version>.zip, aeropeek.rb. Uploading the zip to a GitHub release tagged
# v<version> and copying the cask into the tap are manual steps.
#
# The version is CFBundleShortVersionString in Resources/Info.plist.
# Every release must be signed with the same "aeropeek Dev" identity: macOS ties the Accessibility and
# Screen Recording grants users gave to it. The identity is self-signed, so the app is not notarized
# and the cask clears the download quarantine after installing.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="aeropeek Dev"
REPO="wickes1/aeropeek"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
# grep reads to the end (no -q): under pipefail an early exit would fail the pipeline through SIGPIPE.
if ! security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" >/dev/null; then
  echo "no \"$IDENTITY\" signing identity: run scripts/make-signing-cert.sh first" >&2
  exit 1
fi

# Two single-arch builds joined with lipo: a multi-arch `swift build` needs full Xcode, this works
# with the Command Line Tools alone.
bin_dir() { swift build -c release --triple "$1-apple-macosx14.0" --scratch-path ".build/release-$1" --show-bin-path; }
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/release-$arch"
done
APP=dist/AeroPeek.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
lipo -create "$(bin_dir arm64)/AeroPeek" "$(bin_dir x86_64)/AeroPeek" -output "$APP/Contents/MacOS/AeroPeek"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

ZIP="dist/AeroPeek-$VERSION.zip"
# No resource forks or extended attributes: they would ride along as ._ files and carry nothing the
# app needs (a bundle's signature lives in its _CodeSignature folder and in the executable).
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" -e "s#@REPO@#$REPO#" packaging/aeropeek.rb.in > dist/aeropeek.rb
echo "built $ZIP ($(lipo -archs "$APP/Contents/MacOS/AeroPeek")), sha256 $SHA"
echo "cask written to dist/aeropeek.rb"
