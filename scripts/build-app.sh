#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --disable-sandbox
APP="$ROOT/dist/Clipboard Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/arm64-apple-macosx/release/ClipboardManagerApp" "$APP/Contents/MacOS/ClipboardManagerApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/ClipboardManagerApp"
codesign --force --sign - "$APP/Contents/MacOS/ClipboardManagerApp"
codesign --force --sign - "$APP"
echo "$APP"
