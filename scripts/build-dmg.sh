#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/Clipboard Manager.app"
DMG="$ROOT/dist/Clipboard Manager.dmg"

"$ROOT/scripts/build-app.sh"

# Stage the volume rather than pointing at the .app directly: the drag-to-install layout needs the
# Applications symlink sitting next to the bundle, which is what makes the mounted disk show the
# usual "drag me there" pairing.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Clipboard Manager" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG"

echo "$DMG"
