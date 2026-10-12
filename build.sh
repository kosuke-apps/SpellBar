#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="SpellBar.app"
BUNDLE_ID="dev.kosuke.SpellBar"
# The one certificate shared by every Mac Utilities app. See docs/code-signing.md.
SIGNING_IDENTITY_NAME="Mac Utilities Code Signing"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SpellBar</string>
  <key>CFBundleDisplayName</key><string>SpellBar</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>CFBundleExecutable</key><string>SpellBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Kosuke Satake. MIT License.</string>
</dict>
</plist>
PLIST

# Generate the icon if it is missing
if [ ! -f Resources/AppIcon.icns ]; then
  rm -rf /tmp/spellbar.iconset
  swift tools/make_icon.swift /tmp/spellbar.iconset
  iconutil -c icns /tmp/spellbar.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Compile the String Catalog into en.lproj and ja.lproj. Having both folders in the bundle is also what makes
# macOS offer a per-app language for SpellBar (System Settings → General → Language & Region → Applications).
python3 tools/check_localization.py
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
xcrun xcstringstool compile --output-directory "$APP/Contents/Resources" Resources/Localizable.xcstrings

swiftc -O \
  -o "$APP/Contents/MacOS/SpellBar" \
  Sources/*.swift \
  -framework Cocoa -framework Carbon

# macOS remembers privacy permissions (Accessibility, Input Monitoring) by the app's designated requirement.
# Signed ad-hoc, that requirement is the binary's hash and every rebuild drops the permissions; signed with the
# certificate, it is the certificate plus the bundle identifier and the permissions survive rebuilds.
#
# `security find-identity` without -v also lists a self-signed certificate the system does not trust. That is
# enough: neither codesign nor the permission database needs the certificate to be trusted.
hashes=$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGNING_IDENTITY_NAME\"" 'index($0, name) { print $2 }' | sort -u)
count=$(printf '%s' "$hashes" | grep -c . || true)

if [ "$count" -eq 1 ]; then
  codesign --force --sign "$hashes" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with \"$SIGNING_IDENTITY_NAME\" ($hashes)"
elif [ "$count" -gt 1 ]; then
  echo "error: $count identities are named \"$SIGNING_IDENTITY_NAME\"; keep one in Keychain Access" >&2
  exit 1
else
  echo "warning: \"$SIGNING_IDENTITY_NAME\" is not in the keychain; signing ad-hoc instead." >&2
  echo "warning: macOS will drop the Accessibility and Input Monitoring permissions on every rebuild." >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "built: $(pwd)/$APP"
