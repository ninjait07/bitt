#!/bin/bash
# Builds BITT.app.
#   --install    also copy it into /Applications
#   --dmg        also write a disk image to keep
#   --out <dir>  where the disk image goes (default: dist/ next to this project)
#   --release    sign with the Developer ID and the hardened runtime, ready to
#                notarise (release.sh drives this)
set -euo pipefail

APP_NAME="BITT"
BUNDLE_ID="com.nonbannawat.bitt"
VERSION="1.0"
MIN_MACOS="13.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$HERE/build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"

INSTALL=0
MAKE_DMG=0
RELEASE=0
DMG_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install) INSTALL=1 ;;
        --dmg) MAKE_DMG=1 ;;
        --release) RELEASE=1 ;;
        --out)
            shift
            DMG_DIR="${1:?--out needs a directory}"
            MAKE_DMG=1
            ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> Compiling the app ($(swiftc --version | head -1 | cut -d' ' -f1-4))"
ARCH_FLAGS=()
if [ "$(uname -m)" = "arm64" ]; then
    ARCH_FLAGS=(-target arm64-apple-macos$MIN_MACOS)
else
    ARCH_FLAGS=(-target x86_64-apple-macos$MIN_MACOS)
fi
swiftc -O -parse-as-library "${ARCH_FLAGS[@]}" \
    -o "$CONTENTS/MacOS/$APP_NAME" \
    "$HERE"/Sources/*.swift "$HERE"/Sources/Engine/*.swift

echo "==> Drawing the icon"
swiftc -O -parse-as-library "${ARCH_FLAGS[@]}" -o "$BUILD/makeicon" \
    "$HERE/Tools/makeicon.swift" "$HERE/Sources/BittMark.swift"
"$BUILD/makeicon" "$BUILD/$APP_NAME.iconset" > /dev/null
rm -f "$BUILD/makeicon"
iconutil -c icns "$BUILD/$APP_NAME.iconset" -o "$CONTENTS/Resources/$APP_NAME.icns"
rm -rf "$BUILD/$APP_NAME.iconset"

# The engine is Swift now and is compiled into the binary above.
[ -f "$HERE/HELP.md" ] && cp "$HERE/HELP.md" "$CONTENTS/Resources/"

echo "==> Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Many BitTorrent trackers are plain http:// and always will be. Without
         this, App Transport Security blocks every one of them and no peers are
         ever found. Peer and UDP traffic goes through Network.framework and is
         unaffected either way. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>BITT asks your router to forward its listening port, so other peers can connect to you.</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>A BitTorrent client built on pytorrent.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>BitTorrent Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>torrent</string></array>
            <key>LSItemContentTypes</key>
            <array><string>org.bittorrent.torrent</string></array>
            <key>CFBundleTypeIconFile</key><string>$APP_NAME</string>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>org.bittorrent.torrent</string>
            <key>UTTypeDescription</key><string>BitTorrent Document</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>torrent</string></array>
                <key>public.mime-type</key><array><string>application/x-bittorrent</string></array>
            </dict>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Magnet Link</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key><array><string>magnet</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ "$RELEASE" = "1" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
    if [ -z "$IDENTITY" ]; then
        echo "==> No Developer ID found; cannot build a release" >&2
        exit 1
    fi
    echo "==> Signing as $IDENTITY (hardened runtime, for notarisation)"
    # No --deep: it is deprecated, and this bundle has nothing nested to sign.
    codesign --force --identifier "$BUNDLE_ID" --sign "$IDENTITY" \
        --options runtime --timestamp "$APP"
    codesign --verify --strict "$APP"
else
    echo "==> Signing (ad-hoc, for this machine)"
    codesign --force --sign - "$APP" 2>/dev/null || \
        echo "    note: ad-hoc signing failed; the app still runs locally"
fi

echo "==> Built $APP"

if [ "$INSTALL" = "1" ]; then
    TARGET="/Applications"
    if [ ! -w "$TARGET" ]; then
        TARGET="$HOME/Applications"
        mkdir -p "$TARGET"
        echo "==> /Applications is not writable, installing to $TARGET"
    fi
    # Stop a running copy so the bundle can be replaced safely.
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$TARGET/$APP_NAME.app"
    cp -R "$APP" "$TARGET/"
    echo "==> Installed $TARGET/$APP_NAME.app"
    # Let Launch Services notice the new document and URL handlers.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$TARGET/$APP_NAME.app" 2>/dev/null || true
fi

if [ "$MAKE_DMG" = "1" ]; then
    echo "==> Building the disk image"
    DIST="${DMG_DIR:-$ROOT/dist}"
    STAGE="$BUILD/dmg"
    IMAGE="$DIST/$APP_NAME-$VERSION.dmg"
    mkdir -p "$DIST"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"

    cp -R "$APP" "$STAGE/"
    # The usual drag-to-install layout.
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/README.md" "$STAGE/อ่านก่อน.md" 2>/dev/null || true

    rm -f "$IMAGE"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
        -ov -format UDZO -quiet "$IMAGE"
    rm -rf "$STAGE"
    echo "==> Installer: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
fi
