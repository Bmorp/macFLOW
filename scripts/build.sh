#!/bin/bash
# Builds Mac Flow.app (universal, Hardened Runtime) and packages a drag-to-install DMG.
#   ./scripts/build.sh                 → dist/Mac Flow.app + dist/MacFlow-<version>.dmg
#   SKIP_DMG=1 ./scripts/build.sh      → app bundle only
#   SIGN_ID="Developer ID Application: …" ./scripts/build.sh   → sign for notarization
#
# Without a Developer ID, a self-signed "Mac Flow Local" code-signing certificate in your login keychain is used if
# present: macOS then recognises each new build as the same app, so Accessibility, Microphone and the rest stay
# granted across updates (ad-hoc builds look new every time). Make it once in Keychain Access › Certificate Assistant
# › Create a Certificate…: Name "Mac Flow Local", Identity Type "Self-Signed Root", Certificate Type "Code Signing".
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Mac Flow"
EXEC_NAME="MacFlow"     # CFBundleExecutable
BIN_NAME="Atoll"        # the Swift package product
DMG_NAME="MacFlow"
VERSION="8.0.0"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
if [ -z "${SIGN_ID:-}" ]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q '"Mac Flow Local"'; then
        SIGN_ID="Mac Flow Local"
    else
        SIGN_ID="-"
    fi
fi
DIST="$ROOT/dist"
WORK="$ROOT/build"
APP="$DIST/$APP_NAME.app"

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
mkdir -p "$WORK" "$DIST"

step "Testing"
swift test 2>&1 | grep -E "Test run with|failed" || true

step "Compiling (release, universal)"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>"$WORK/build.log"; then
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    echo "Universal build failed (see build/build.log) — building for this Mac only"
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi
lipo -info "$BIN_DIR/$BIN_NAME"

step "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$BIN_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/"
# StandBy's 4K wallpapers (rendered by scripts/wallpapers; HEIC, with depth layers for three of them).
mkdir -p "$APP/Contents/Resources/Wallpapers"
cp "$ROOT"/Resources/Wallpapers/*.heic "$APP/Contents/Resources/Wallpapers/"
cp "$ROOT/scripts/atoll" "$APP/Contents/Resources/atoll"   # command-line helper for your own Live Activities
printf "APPL????" > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

step "Compiling Liquid Glass icon (Icon Composer → actool)"
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$WORK/icon-partial.plist" >/dev/null
ls "$APP/Contents/Resources"

step "Signing (Hardened Runtime)"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Resources/Atoll.entitlements" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok ($([ "$SIGN_ID" = "-" ] && echo "ad-hoc: permissions reset each build" || echo "$SIGN_ID"))"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -c "com.apple.security" | xargs echo "entitlements:"

if [[ "${SKIP_DMG:-0}" == "1" ]]; then
    echo "App ready: $APP"
    exit 0
fi

step "Building DMG"
swift "$ROOT/scripts/make_art.swift" "$WORK/art" >/dev/null
DMG="$DIST/$DMG_NAME-$VERSION.dmg"
RW_DMG="$WORK/$DMG_NAME-rw.dmg"
STAGE="$WORK/dmg-stage"
rm -rf "$STAGE" "$RW_DMG" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck "$WORK/art/dmg_bg.png" "$WORK/art/dmg_bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 80m -ov "$RW_DMG" >/dev/null
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="$(echo "$ATTACH_OUT" | grep -E '/Volumes/' | sed -E 's/.*(\/Volumes\/.*)$/\1/' | head -1)"
VOL_NAME="$(basename "$MOUNT")"

osascript <<EOF || echo "(Finder layout skipped — the DMG still works)"
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MOUNT" || true; fi

sync
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"
hdiutil verify "$DMG" 2>&1 | tail -1

step "Done"
ls -lh "$DMG"
