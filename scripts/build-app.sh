#!/bin/bash
# Builds Bekitzur.app, installs it in ~/Applications, and opens it. Won't replace the app while it's recording.
#
# Signs ad-hoc, without a certificate. By default an ad-hoc signature identifies the app by this build's hash, so macOS
# treats every build as a new app and asks for the microphone and system audio permissions again. The designated
# requirement below identifies it by bundle identifier instead.
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftPM points the linker at XCTest folders that the Command Line Tools don't have; those warnings are harmless.
swift build -c release --product BekitzurApp 2>&1 | grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer"
# Not `swift build --show-bin-path`: it discards the build state, so the next build starts from scratch.
bin=.build/release
app=build/Bekitzur.app
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" App/Info.plist)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp App/Info.plist "$app/Contents/Info.plist"
cp -R App/Resources "$app/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$app/Contents/Info.plist"
cp "$bin/BekitzurApp" "$app/Contents/MacOS/Bekitzur"
cp -R "$bin/whisper.framework" "$bin/llama.framework" "$app/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Bekitzur"

codesign --remove-signature "$app/Contents/MacOS/Bekitzur" "$app"/Contents/Frameworks/*.framework
for framework in "$app"/Contents/Frameworks/*.framework; do
    codesign --sign - "$framework"
done
codesign --sign - --requirements "=designated => identifier \"$bundle_id\"" "$app"
codesign --verify --strict "$app"

if pgrep -x Bekitzur >/dev/null; then
    if grep -qs '"status" : "recording"' "$HOME/Library/Application Support/Bekitzur/Conversations"/*/info.json; then
        echo "Built, but not installed: Bekitzur is recording. Run this again after you stop the recording." >&2
        exit 1
    fi
    pkill -x Bekitzur
    while pgrep -x Bekitzur >/dev/null; do sleep 0.2; done
fi
rm -rf ~/Applications/Bekitzur.app
mkdir -p ~/Applications
cp -R "$app" ~/Applications/
open -g ~/Applications/Bekitzur.app --args --background
echo "Installed and opened ~/Applications/Bekitzur.app"
