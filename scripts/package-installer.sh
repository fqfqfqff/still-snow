#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
app="$PWD/build/Still Snow.app"
info="$app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$info")"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw "$info")"
arch="$(lipo -archs "$app/Contents/MacOS/StillSnow")"
case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported installer architecture: $arch" >&2; exit 1 ;;
esac
destination="${1:-build/StillSnow-$version-macOS-$arch.pkg}"
stage="$(mktemp -d "$PWD/build/pkg.XXXXXX")"
trap 'rm -r "$stage"' EXIT

codesign --verify --deep --strict "$app"
mkdir "$stage/payload"
ditto "$app" "$stage/payload/Still Snow.app"
cat > "$stage/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
    <key>RootRelativeBundlePath</key><string>Still Snow.app</string>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><true/>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
pkgbuild --root "$stage/payload" --component-plist "$stage/components.plist" \
    --identifier org.stillsnow.macos.installer --version "$version" \
    --install-location /Applications "$stage/still-snow.pkg"

cat > "$stage/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Still Snow</title>
  <options customize="never" require-scripts="false" hostArchitectures="$arch"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <allowed-os-versions>
    <os-version min="$minimum_os"/>
  </allowed-os-versions>
  <choices-outline><line choice="app"/></choices-outline>
  <choice id="app" visible="false"><pkg-ref id="org.stillsnow.macos.installer"/></choice>
  <pkg-ref id="org.stillsnow.macos.installer" version="$version" onConclusion="none">still-snow.pkg</pkg-ref>
</installer-gui-script>
DIST
sign_flags=()
if [[ -n "${STILLSNOW_INSTALLER_IDENTITY:-}" ]]; then
    sign_flags=(--sign "$STILLSNOW_INSTALLER_IDENTITY")
fi
productbuild ${sign_flags[@]+"${sign_flags[@]}"} --distribution "$stage/distribution.xml" --package-path "$stage" "$destination"
