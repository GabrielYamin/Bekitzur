#!/bin/bash
# Installs a precompiled Bekitzur.app and the model files it reads. There is nothing to compile.
#
# Hand someone this script next to Bekitzur.app. The weights are not in that bundle: they download from Hugging
# Face into ~/Library/Application Support/Bekitzur/Models, which is where the app looks. A model file that is
# already there, and isn't the pinned download, is left in place. Speaker models are separate; FluidAudio
# fetches them on the first Conversation, which needs the network once.
#
# Won't replace the app while it's recording.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
models="$HOME/Library/Application Support/Bekitzur/Models"
installed="$HOME/Applications/Bekitzur.app"

# Pinned revisions. The checksums are the Git LFS hashes published for those commits.
hebrew_url="https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/2130c78e4a9cb4914cc4df91a1c3031407789705/ggml-model.bin"
hebrew_sha="c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"
hebrew_bytes=1624555275

english_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin"
english_sha="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
english_bytes=1624555275

# Google's QAT Q4_0 GGUF, saved under the name the app loads.
gemma_url="https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/d1c082be9cf3c8a514acf63b8761f4b41935842e/gemma-4-26B_q4_0-it.gguf"
gemma_sha="3eca3b8f6d7baf218a7dd6bba5fb59a56ee25fe2d567b6f5f589b4f697eca51d"
gemma_bytes=14439363584

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

# A downloaded app is quarantined, and an ad-hoc signature then needs Open Anyway. Clearing the attribute lets the
# copy in ~/Applications open.
install_app() {
    if pgrep -x Bekitzur >/dev/null; then
        if grep -qs '"status" : "recording"' "$HOME/Library/Application Support/Bekitzur/Conversations"/*/info.json; then
            echo "Bekitzur is recording, so the app was not replaced. Run this again after you stop the recording." >&2
            return 1
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
}

matches() {
    local sha=$1 file=$2
    (cd "$(dirname "$file")" && echo "$sha  $(basename "$file")" | shasum -a 256 -c - >/dev/null)
}

fetch() {
    local label=$1 url=$2 sha=$3 bytes=$4 path=$5
    mkdir -p "$(dirname "$path")"
    if [ -f "$path" ]; then
        local size
        size=$(stat -f %z "$path")
        if [ "$size" -eq "$bytes" ] && matches "$sha" "$path"; then
            echo "$label is already installed."
            return
        fi
        # A finished file with a different checksum is a copy this machine already uses. Don't replace it.
        if [ "$size" -gt 100000000 ]; then
            echo "$label is already at $path and differs from the pinned download, so it was left in place."
            return
        fi
        rm -f "$path"
    fi

    local partial="$path.partial"
    local avail
    avail=$(df -k "$(dirname "$path")" | awk 'NR==2 { print $4 }')
    local have=0
    if [ -f "$partial" ]; then
        have=$(stat -f %z "$partial")
    fi
    if [ $((avail * 1024 + have)) -lt "$bytes" ]; then
        echo "Not enough free disk for $label. It needs about $((bytes / 1000000000)) GB." >&2
        exit 1
    fi

    local whole=$((bytes / 1000000000)) tenth=$(((bytes % 1000000000) / 100000000))
    echo "Downloading $label (${whole}.${tenth} GB)..."
    curl -L --fail --retry 5 --retry-delay 5 --retry-connrefused -C - --output "$partial" "$url"
    echo "Checking $label..."
    if ! matches "$sha" "$partial"; then
        rm -f "$partial"
        echo "The download for $label didn't match the pinned file. It was deleted; run this script again." >&2
        exit 1
    fi
    mv "$partial" "$path"
}

if [ -z "$app" ]; then
    echo "No Bekitzur.app next to this script or in build/. The models will still download." >&2
fi

did_install=0
if [ -n "$app" ]; then
    install_app || exit 1
    did_install=1
fi

fetch "Hebrew speech model" "$hebrew_url" "$hebrew_sha" "$hebrew_bytes" "$models/ivrit-ai-whisper-large-v3-turbo-ggml/ggml-model.bin"
fetch "English speech model" "$english_url" "$english_sha" "$english_bytes" "$models/whisper-large-v3-turbo-ggml/ggml-large-v3-turbo.bin"
fetch "Language model" "$gemma_url" "$gemma_sha" "$gemma_bytes" "$models/gemma-4-26b-a4b-it-qat/model.gguf"

if [ "$did_install" -eq 1 ]; then
    open "$installed"
    echo "Opened Bekitzur. The first Conversation downloads the speaker models. macOS will ask for the microphone and system audio."
elif [ -z "$app" ]; then
    echo "Put Bekitzur.app next to this script and run it again." >&2
    exit 1
fi
