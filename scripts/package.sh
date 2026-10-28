#!/bin/bash
# Builds Bekitzur.app from the current code and packs it with install.sh into build/Bekitzur.zip, the file to hand
# someone. Unlike build-app.sh it doesn't install or open the app, so it can run while Bekitzur is recording.
#
#   scripts/package.sh           writes build/Bekitzur.app and build/Bekitzur.zip
#   scripts/package.sh <folder>  writes them to <folder> instead
#
# BEKITZUR_VERSION, like 0.2.0, sets the version people see; releases set it from their tag.
#
# The app is built and signed as build-app.sh does it; a change to one belongs in the other.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build}
# The zip keeps each file's permissions, so they shouldn't depend on the umask of whoever packs it.
umask 022

# SwiftPM points the linker at XCTest folders that the Command Line Tools don't have; those warnings are harmless.
# Lower priority, so a recording's live transcription keeps up.
nice -n 10 swift build -c release --product BekitzurApp 2>&1 | grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer"
bin=.build/release
app="$out/Bekitzur.app"
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" App/Info.plist)
version=$(date +%Y%m%d%H%M)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "an unknown commit")
git diff --quiet HEAD 2>/dev/null || commit="$commit plus uncommitted changes"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp App/Info.plist "$app/Contents/Info.plist"
cp -R App/Resources "$app/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
if [ -n "${BEKITZUR_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BEKITZUR_VERSION" "$app/Contents/Info.plist"
fi
cp "$bin/BekitzurApp" "$app/Contents/MacOS/Bekitzur"
cp -R "$bin/whisper.framework" "$bin/llama.framework" "$app/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Bekitzur"

codesign --remove-signature "$app/Contents/MacOS/Bekitzur" "$app"/Contents/Frameworks/*.framework
for framework in "$app"/Contents/Frameworks/*.framework; do
    codesign --sign - "$framework"
done
codesign --sign - --requirements "=designated => identifier \"$bundle_id\"" "$app"
codesign --verify --strict "$app"

# ditto keeps the frameworks' symbolic links, which the signature covers; zip -r would store copies of their targets.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/Bekitzur"
cp -R "$app" scripts/install.sh "$staging/Bekitzur/"
rm -f "$out/Bekitzur.zip"
ditto -c -k --keepParent "$staging/Bekitzur" "$out/Bekitzur.zip"
echo "Built $out/Bekitzur.app (build $version, from $commit) and $out/Bekitzur.zip"
