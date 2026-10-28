#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, SwiftPM doesn't hand Swift Testing's macro plugin
# to the compiler, so pass its folder explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
