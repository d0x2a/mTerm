#!/usr/bin/env bash
# Builds a signed + notarized + stapled mTerm.app and mTerm-<version>.dmg
# under ./build/.
#
# Optional env vars
# -----------------
#   BUNDLE_ID    Defaults to com.d0x2a.mTerm.
#   VERSION      Defaults to current version. Goes into both
#                CFBundleShortVersionString and CFBundleVersion.
#   UNIVERSAL    If set to 1, builds a universal arm64+x86_64 binary.
#                Default: current host arch only.

set -euo pipefail

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Dox2A Labs LLC (7JD669BMB4)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mterm-notary}"
BUNDLE_ID="${BUNDLE_ID:-com.d0x2a.mTerm}"
VERSION="${VERSION:-0.6.2}"
UNIVERSAL="${UNIVERSAL:-0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/mTerm.app"
ICONSET="$BUILD/AppIcon.iconset"
DMG="$BUILD/mTerm-$VERSION.dmg"
ZIP="$BUILD/mTerm.zip"

echo "▶ cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ building release binary"
# The arch flags have to be on --show-bin-path too: a universal build lands in
# .build/apple/Products/Release, and asking without them hands back the
# host-arch path instead — which is how UNIVERSAL=1 used to ship arm64-only.
BUILD_FLAGS=(-c release)
if [[ "$UNIVERSAL" == "1" ]]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
cp "$BIN_DIR/mTerm" "$APP/Contents/MacOS/mTerm"

if [[ "$UNIVERSAL" == "1" ]]; then
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/mTerm")"
    [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || {
        echo "✗ expected a universal binary, got: $ARCHS" >&2
        exit 1
    }
    echo "  universal binary: $ARCHS"
fi

echo "▶ writing Info.plist (bundle=$BUNDLE_ID, version=$VERSION)"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

echo "▶ baking AppIcon.icns"
"$APP/Contents/MacOS/mTerm" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▶ codesigning .app"
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/Entitlements.plist" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --timestamp \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▶ submitting .app for notarization (this can take a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "▶ creating DMG"
# Render the HiDPI background image (mTerm itself exports the PNGs;
# tiffutil packs @1x + @2x into a single .tiff so Finder picks the right
# rep on Retina displays).
BG_DIR="$BUILD/dmg-bg"
"$APP/Contents/MacOS/mTerm" --export-dmg-background "$BG_DIR"
tiffutil -cathidpicheck "$BG_DIR/background.png" "$BG_DIR/background@2x.png" \
    -out "$BG_DIR/background.tiff" >/dev/null

# create-dmg (from Homebrew) handles layout: positions mTerm.app on the
# left, an Applications drop-link on the right, and paints the background.
# It returns non-zero if a Finder AppleScript step transiently fails, so
# we ignore exit status as long as the DMG actually got written.
create-dmg \
    --volname "mTerm $VERSION" \
    --background "$BG_DIR/background.tiff" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "mTerm.app" 150 200 \
    --app-drop-link 450 200 \
    --no-internet-enable \
    "$DMG" \
    "$APP" || true
test -f "$DMG"

echo "▶ codesigning DMG"
codesign --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --timestamp \
    "$DMG"

echo "▶ submitting DMG for notarization"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG"

echo "▶ verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo
echo "✓ built: $DMG"
