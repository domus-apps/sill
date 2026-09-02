#!/bin/bash
# Runs the unit tests. Kept as the stable entry point even though it is
# mostly a passthrough — with full Xcode installed, plain `swift test`
# needs no extra flags. (Command Line Tools alone can't run Swift Testing.)
set -euo pipefail
cd "$(dirname "$0")/.."

# Some toolchains stage Sparkle.framework next to the app binary but not in
# PackageFrameworks, which is where the test bundle's rpath points — mirror
# it so the bundle can load.
swift build --build-tests
STAGED=.build/out/Products/Debug/Sparkle.framework
DEST=.build/out/Products/Debug/PackageFrameworks
if [[ -d "$STAGED" && ! -d "$DEST/Sparkle.framework" ]]; then
    mkdir -p "$DEST"
    cp -R "$STAGED" "$DEST/"
fi

swift test "$@"
