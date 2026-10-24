#!/bin/sh
# Runs the NovelNestCore tests. Works with full Xcode or with only the
# Command Line Tools, where the Swift Testing framework isn't on the default
# search path and its Testing+Foundation overlay module is missing.
set -e
cd "$(dirname "$0")/../NovelNestCore"

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if xcrun --find xcodebuild >/dev/null 2>&1 || [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
    exec swift test "$@"
fi
exec swift test \
    -Xswiftc -F"$FRAMEWORKS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F"$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "$@"
