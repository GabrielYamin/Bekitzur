#!/bin/bash
# Installs a precompiled Bekitzur.app. There is nothing to compile.
#
# Hand someone this script next to Bekitzur.app. The models aren't in that bundle: the app downloads them from Hugging
# Face into ~/Library/Application Support/Bekitzur/Models, showing its progress, and keeps the ones already there.
#
# Won't replace the app while it's recording.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
installed="$HOME/Applications/Bekitzur.app"

app=""
if [ $# -gt 0 ]; then
    app=$1
    if [ ! -d "$app" ]; then
        echo "No app at $app" >&2
        exit 1
    fi
else
    for candidate in "$root/Bekitzur.app" "$root/../build/Bekitzur.app"; do
        if [ -d "$candidate" ]; then
            app=$(cd "$candidate" && pwd)
            break
        fi
    done
fi

if [ -z "$app" ]; then
    echo "No Bekitzur.app next to this script or in build/. Put Bekitzur.app next to this script and run it again." >&2
    exit 1
fi

# A downloaded app is quarantined, and an ad-hoc signature then needs Open Anyway. Clearing the attribute lets the
# copy in ~/Applications open.
if pgrep -x Bekitzur >/dev/null; then
    if grep -qs '"status" : "recording"' "$HOME/Library/Application Support/Bekitzur/Conversations"/*/info.json; then
        echo "Bekitzur is recording, so the app was not replaced. Run this again after you stop the recording." >&2
        exit 1
    fi
    pkill -x Bekitzur || true
    while pgrep -x Bekitzur >/dev/null; do sleep 0.2; done
fi
xattr -dr com.apple.quarantine "$app" || true
mkdir -p "$HOME/Applications"
rm -rf "$installed"
cp -R "$app" "$installed"
xattr -dr com.apple.quarantine "$installed" || true
echo "Installed $installed"

open "$installed"
echo "Opened Bekitzur. If it doesn't have its models yet, choose Download in its window (about 18 GB). macOS asks for the microphone and system audio on the first recording."
