#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="SpellBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SpellBar</string>
  <key>CFBundleDisplayName</key><string>SpellBar</string>
  <key>CFBundleIdentifier</key><string>local.spellbar</string>
  <key>CFBundleExecutable</key><string>SpellBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
PLIST

# アイコンが無ければ生成する
if [ ! -f Resources/AppIcon.icns ]; then
  rm -rf /tmp/spellbar.iconset
  swift tools/make_icon.swift /tmp/spellbar.iconset
  iconutil -c icns /tmp/spellbar.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O \
  -o "$APP/Contents/MacOS/SpellBar" \
  Sources/*.swift \
  -framework Cocoa -framework Carbon

# TCC (アクセシビリティ/入力監視) は署名で同一アプリか判断するため、ad-hoc でも署名しておく
codesign --force --sign - --identifier local.spellbar "$APP" >/dev/null 2>&1 || true

echo "built: $(pwd)/$APP"
