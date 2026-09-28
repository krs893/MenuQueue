#!/bin/bash
# Builds MenuQueue.app — a plain swiftc build, no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MenuQueue.app"
BIN="$APP/Contents/MacOS/MenuQueue"

rm -rf "$APP"
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
    <key>CFBundleShortVersionString</key>    <string>1.3.1</string>
    <key>CFBundleVersion</key>               <string>6</string>
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
    -target "${ARCH:-$(uname -m)}-apple-macos14.0" \
    -O -whole-module-optimization \
    -framework AppKit -framework SwiftUI -framework ApplicationServices \
    -framework ServiceManagement \
    -o "$BIN" \
    Sources/*.swift

# Ad-hoc signing supports local use. A changed binary may require Automation
# or Accessibility permission again; a stable identifier alone does not prevent this.
# An ad-hoc signature is identified by the binary's cdhash, so every rebuild
# produces a new identity and macOS quietly drops the Accessibility grant:
# the entry stays visible and switched on in System Settings while
# AXIsProcessTrusted() returns false, with no new prompt. Signing with a
# local self-signed certificate keeps the identity stable across rebuilds.
IDENTITY="MenuQueue Local Signing"
# Not `-v`: that lists only identities the system trusts, and a local
# self-signed certificate is not one. It does not need to be — codesign signs
# with it all the same, and the designated requirement becomes the certificate
# ("certificate leaf = H..."), so Automation and Accessibility grants survive
# rebuilds instead of being tied to one binary's hash. Signing by the SHA-1
# avoids picking up anything else with a similar name.
IDENTITY_HASH=$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$IDENTITY\"" '$0 ~ name { print $2; exit }')
if [ -n "$IDENTITY_HASH" ]; then
    codesign --force --sign "$IDENTITY_HASH" --identifier jp.local.menuqueue "$APP"
    echo "signed with: $IDENTITY ($IDENTITY_HASH) — permission grants survive rebuilds"
else
    PREVIOUS=$(codesign -dvvv "$HOME/Applications/MenuQueue.app" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')
    codesign --force --sign - --identifier jp.local.menuqueue "$APP"
    CURRENT=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')
    echo "signed ad-hoc"
    if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$CURRENT" ]; then
        echo "  note: cdhash changed ($PREVIOUS -> $CURRENT)."
        echo "  The installed app's Accessibility grant no longer matches. After installing, run:"
        echo "    tccutil reset Accessibility jp.local.menuqueue"
        echo "  then reopen the app and approve the prompt."
    fi
fi

echo "built → $APP"
