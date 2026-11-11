#!/bin/zsh
# Builds Arclight.app (release) into ./dist, ad-hoc signed. No Xcode needed.
# The same binary inside the bundle also serves the CLI and MCP:
#   dist/Arclight.app/Contents/MacOS/arclight mcp
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/arclight"

APP="dist/Arclight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/arclight"

# App icon from Resources/AppIcon.png (1024²).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Arclight</string>
  <key>CFBundleDisplayName</key><string>Arclight</string>
  <key>CFBundleIdentifier</key><string>com.xndrpr.arclight</string>
  <key>CFBundleExecutable</key><string>arclight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Arclight Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>com.xndrpr.arclight.project</string><string>com.xndrpr.apogee.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.xndrpr.arclight.project</string>
      <key>UTTypeDescription</key><string>Arclight Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.directory</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>arclight</string></array></dict>
    </dict>
  </array>
  <!-- Projects from before the rename (Apogee) still open. -->
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.xndrpr.apogee.project</string>
      <key>UTTypeDescription</key><string>Apogee Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.directory</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>apogee</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Signing. Default: ad-hoc ("-"), which is enough to run on the Mac that built it.
# With an Apple Developer ID (paid account) set DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
# and optionally NOTARY_PROFILE (from `xcrun notarytool store-credentials`) to notarize, so the app
# opens on any Mac without warnings. See docs/install.md.
xattr -cr "$APP"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" dist/Arclight-notarize.zip
    xcrun notarytool submit dist/Arclight-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm dist/Arclight-notarize.zip
  fi
else
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"
du -sh "$APP"
echo "Built $APP"
