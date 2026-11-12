#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
vendor="$PWD/build/vendor"
archive="$vendor/Sparkle-$version.tar.xz"
framework="$vendor/sparkle-$version"
mkdir -p "$vendor"

if [[ ! -f "$archive" ]]; then
    download="$(mktemp "$vendor/sparkle-download.XXXXXX")"
    trap 'rm -f "$download"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --retry 2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        -o "$download"
    printf '%s  %s\n' "$digest" "$download" | shasum -a 256 -c - >&2
    mv "$download" "$archive"
fi
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c - >&2

if [[ ! -f "$framework/Sparkle.framework/Sparkle" || ! -x "$framework/bin/generate_appcast" ]]; then
    mkdir -p "$framework"
    tar -xf "$archive" -C "$framework" ./Sparkle.framework ./bin ./LICENSE
fi
codesign --verify --deep --strict "$framework/Sparkle.framework"
printf '%s\n' "$framework"
