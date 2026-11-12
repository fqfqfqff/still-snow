#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
destination="${1:-build/StillSnow-macos-$(uname -m).dmg}"
stage="$(mktemp -d "$PWD/build/dmg.XXXXXX")"
trap 'rm -r "$stage"' EXIT
app="$PWD/build/Still Snow.app"

codesign --verify --deep --strict "$app"
ditto "$app" "$stage/Still Snow.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Still Snow" -srcfolder "$stage" -format UDZO -ov "$destination"
hdiutil verify "$destination"
