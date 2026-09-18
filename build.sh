#!/bin/bash
# Builds MenuQueue.app — a plain swiftc build, no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MenuQueue.app"
BIN="$APP/Contents/MacOS/MenuQueue"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>MenuQueue</string>
    <key>CFBundleDisplayName</key>           <string>MenuQueue</string>
    <key>CFBundleExecutable</key>            <string>MenuQueue</string>
    <key>CFBundleIdentifier</key>            <string>jp.local.menuqueue</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>ミュージック.app の再生状況を読み取り、キューの曲を再生するために使用します。</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>ライブラリの曲を検索してキューに追加するために使用します。</string>
</dict>
</plist>
PLIST

echo "checking AppleScript sources…"
python3 check_scripts.py

echo "compiling…"
swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -O -whole-module-optimization \
    -framework AppKit -framework SwiftUI -framework ApplicationServices \
    -framework ServiceManagement \
    -o "$BIN" \
    Sources/*.swift

# Ad-hoc signature with a stable identifier keeps the Automation/Accessibility
# grants attached across rebuilds instead of re-prompting every time.
codesign --force --sign - --identifier jp.local.menuqueue "$APP"

echo "built → $APP"
