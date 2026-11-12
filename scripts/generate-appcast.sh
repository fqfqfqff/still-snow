#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 || -z "${STILLSNOW_UPDATE_PRIVATE_KEY_FILE:-}" ]]; then
    echo 'Usage: STILLSNOW_UPDATE_PRIVATE_KEY_FILE=/private/path ./scripts/generate-appcast.sh <archives> <download-url-prefix>' >&2
    exit 1
fi

archives="$(cd "$1" && pwd -P)"
prefix="$2"
key="${STILLSNOW_UPDATE_PRIVATE_KEY_FILE}"
key_directory="$(cd "$(dirname "$key")" && pwd -P)"
key="$key_directory/$(basename "$key")"
if [[ ! -f "$key" || -L "$key" || "$key_directory/" == "$archives/"* ]]; then
    echo 'Keep the private update key in a regular file outside the archives directory.' >&2
    exit 1
fi
if [[ "$prefix" != https://* ]]; then
    echo 'The download URL prefix must use HTTPS.' >&2
    exit 1
fi

sparkle="$(scripts/fetch-sparkle.sh)"
"$sparkle/bin/generate_appcast" --ed-key-file "$key" \
    --download-url-prefix "${prefix%/}/" --maximum-deltas 0 --embed-release-notes "$archives"
"$sparkle/bin/sign_update" --ed-key-file "$key" --verify "$archives/appcast.xml"
