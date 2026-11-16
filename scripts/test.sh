#!/usr/bin/env bash
# swift test. With the Command Line Tools as the active toolchain (no Xcode), Swift Testing is only
# found when its framework paths are passed in.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d "$F/Testing.framework" ]]; then
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
