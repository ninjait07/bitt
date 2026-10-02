#!/bin/bash
# Packs a release: build with the Developer ID → notarise the app → dmg →
# notarise the dmg → staple both. The result opens on any Mac without warnings.
#
#   ./release.sh 1.0
#
# The notary credentials live in the keychain. To create them once:
#   xcrun notarytool store-credentials bitt-notary \
#       --apple-id you@example.com --team-id 9FT88D47SP --password <app-specific>
# BITT_NOTARY_PROFILE overrides which profile is used.
set -euo pipefail

VERSION="${1:?usage: ./release.sh <version>}"
PROFILE="${BITT_NOTARY_PROFILE:-deft-notary}"
APP_NAME="BITT"

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$ROOT/macapp/build/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

echo "==> [1/6] Building $APP_NAME $VERSION signed for release"
bash "$ROOT/macapp/build.sh" --release

echo "==> [2/6] Notarising the app (Apple usually takes 1–5 minutes)"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

echo "==> [3/6] Stapling the app"
xcrun stapler staple "$APP"

echo "==> [4/6] Building the disk image from the stapled app"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.th.md" "$STAGE/อ่านก่อน.md" 2>/dev/null || true
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"
IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> [5/6] Notarising the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> [6/6] Stapling the disk image"
xcrun stapler staple "$DMG"
rm -rf "$STAGE"

echo
echo "==> Gatekeeper says:"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /'
echo
echo "==> Ready: $DMG"
echo "    shasum -a 256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "    Publish it with:"
echo "      gh release create v$VERSION \"$DMG\" --title \"$APP_NAME $VERSION\" --notes \"...\""
