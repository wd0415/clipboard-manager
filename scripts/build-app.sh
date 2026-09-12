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

# Sign with a certificate, not ad-hoc.
#
# An ad-hoc signature carries no Team ID, so its designated requirement collapses to a bare
# cdhash — which is a different value after every rebuild. TCC pins that requirement when the
# grant is created and never regenerates it (flipping the switch in System Settings only writes
# the auth_value column), so an ad-hoc build silently loses the Accessibility grant on every
# rebuild while System Settings keeps showing the toggle as ON. A certificate-backed requirement
# is identity-based and outlives the build, so the grant is given once.
#
# Override with CODESIGN_IDENTITY, or set it to `-` to go back to ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-Apple Development: woden0415@gmail.com (T942J42MF7)}"
if ! security find-identity -v -p codesigning | grep -qF -- "$IDENTITY"; then
    echo "warning: signing identity '$IDENTITY' not in the keychain; signing ad-hoc instead." >&2
    echo "warning: the Accessibility grant will have to be re-granted after this build." >&2
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/ClipboardManagerApp"
codesign --force --sign "$IDENTITY" "$APP"
echo "$APP"
