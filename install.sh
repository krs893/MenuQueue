#!/bin/bash
# Install a verified build without stopping the app or opening it.
set -euo pipefail

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [applications-directory]\n' "$0" >&2
    exit 2
fi
if [ "${1:-}" = "--help" ]; then
    printf 'Usage: %s [applications-directory]\nDefault: ~/Applications\n' "$0"
    exit 0
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE="$PROJECT_DIR/build/MenuQueue.app"
INSTALL_DIR="${1:-$HOME/Applications}"
BUNDLE_ID="jp.local.menuqueue"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "$SOURCE" ]; then
    echo '先に ./build.sh を実行してください。' >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$SOURCE"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" != "$BUNDLE_ID" ]; then
    echo 'ビルドのbundle IDが一致しません。' >&2
    exit 1
fi

check_running() {
    if /usr/bin/pgrep -x MenuQueue >/dev/null; then
        echo 'MenuQueue が起動中です。メニューバーの「MenuQueue を終了」後に再実行してください。' >&2
        exit 1
    fi
}
check_running

mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
TARGET="$INSTALL_DIR/MenuQueue.app"
if [ "$TARGET" = "$SOURCE" ] || [ -L "$TARGET" ]; then
    echo 'ビルドと同じ場所やシンボリックリンクにはインストールできません。' >&2
    exit 1
fi
if [ -e "$TARGET" ]; then
    /usr/bin/codesign --verify --strict "$TARGET"
    PREVIOUS_REQUIREMENT="$(/usr/bin/codesign -d -r- "$TARGET" 2>&1 | sed -n 's/^designated => //p')"
    CURRENT_REQUIREMENT="$(/usr/bin/codesign -d -r- "$SOURCE" 2>&1 | sed -n 's/^designated => //p')"
    if [ -z "$CURRENT_REQUIREMENT" ] || [ "$PREVIOUS_REQUIREMENT" != "$CURRENT_REQUIREMENT" ]; then
        echo '署名の指定要件が変わっています。既存の許可を維持できないためインストールを中止しました。' >&2
        exit 1
    fi
fi

# Copy and verify before replacing; retain the old app until the move succeeds.
INSTALL_WORK="$(mktemp -d "$INSTALL_DIR/.menuqueue-install.XXXXXX")"
cleanup() {
    if [ ! -e "$TARGET" ] && [ -d "$INSTALL_WORK/previous.app" ]; then
        if ! /bin/mv "$INSTALL_WORK/previous.app" "$TARGET"; then
            echo "旧アプリを復元できませんでした。保存先: $INSTALL_WORK/previous.app" >&2
            return
        fi
    fi
    rm -rf "$INSTALL_WORK"
}
trap cleanup EXIT
/usr/bin/ditto "$SOURCE" "$INSTALL_WORK/MenuQueue.app"
/usr/bin/codesign --verify --strict "$INSTALL_WORK/MenuQueue.app"
check_running
if [ -e "$TARGET" ]; then
    /bin/mv "$TARGET" "$INSTALL_WORK/previous.app"
fi
if ! /bin/mv "$INSTALL_WORK/MenuQueue.app" "$TARGET"; then
    exit 1
fi

if ! "$LSREGISTER" -f "$TARGET"; then
    echo "アプリは保存済みですが、Launch Services 登録に失敗しました: $TARGET" >&2
    exit 1
fi
if ! /usr/bin/mdimport -i "$TARGET"; then
    echo "アプリは保存・登録済みですが、Spotlight 索引の要求に失敗しました: $TARGET" >&2
    exit 1
fi
echo "installed → $TARGET"
echo 'Launch Services 登録と Spotlight 索引を要求しました。⌘ Space → MenuQueue で開けます。'
