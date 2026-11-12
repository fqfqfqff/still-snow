#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-build}"
arch="$(uname -m)"
sparkle="$(scripts/fetch-sparkle.sh)"
version="${STILLSNOW_VERSION:-0.2.0}"
build_number="${STILLSNOW_BUILD_NUMBER:-4}"
feed="${STILLSNOW_UPDATE_FEED:-}"
public_key="${STILLSNOW_UPDATE_PUBLIC_KEY:-}"
update_flags=()
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid application version or build number." >&2
    exit 1
fi
if [[ -n "$feed" || -n "$public_key" ]]; then
    if [[ ! "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        echo "An EdDSA public key is required for a configured update feed." >&2
        exit 1
    fi
    if [[ "${STILLSNOW_UPDATE_TEST:-0}" == 1 && "$feed" == http://127.0.0.1:* ]]; then
        update_flags=(-D UPDATE_TEST)
    elif [[ "$feed" != https://* ]]; then
        echo "The public update feed must use HTTPS." >&2
        exit 1
    fi
fi
app="$out/Still Snow.app"
mkdir -p "$out/module-cache"
stage="$(mktemp -d "$out/.stillsnow.XXXXXX")"
trap 'rm -r "$stage"' EXIT
candidate="$stage/Still Snow.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources" "$candidate/Contents/Frameworks"

swiftc -O -module-cache-path "$out/module-cache" -target "$arch-apple-macosx14.0" \
    -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    ${update_flags[@]+"${update_flags[@]}"} \
    Sources/Snow.swift Sources/Desktop.swift Sources/Settings.swift Sources/Updates.swift Sources/main.swift \
    -o "$candidate/Contents/MacOS/StillSnow"

plist="$candidate/Contents/Info.plist"
cp Resources/Info.plist "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build_number" "$plist"
if [[ -n "$feed" ]]; then
    plutil -insert SUFeedURL -string "$feed" "$plist"
    plutil -insert SUPublicEDKey -string "$public_key" "$plist"
    plutil -insert SURequireSignedFeed -bool YES "$plist"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
    plutil -insert SUEnableAutomaticChecks -bool YES "$plist"
    plutil -insert SUAutomaticallyUpdate -bool YES "$plist"
fi
if [[ "${STILLSNOW_UPDATE_TEST:-0}" == 1 && "$feed" == http://127.0.0.1:* ]]; then
    plutil -replace CFBundleIdentifier -string org.stillsnow.macos.updatetest "$plist"
    plutil -insert NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true,"NSExceptionDomains":{"127.0.0.1":{"NSExceptionAllowsInsecureHTTPLoads":true}}}' "$plist"
fi
ditto "$sparkle/Sparkle.framework" "$candidate/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$candidate/Contents/Resources/Sparkle-LICENSE.txt"
cp Resources/StillSnow.icns Resources/StillSnow.png Resources/Icon*.png "$candidate/Contents/Resources/"
codesign --force --sign - "$candidate"
codesign --verify --deep --strict "$candidate"
if [[ -d "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$candidate" "$app"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
    exit 1
fi
printf 'Built %s\n' "$app"
