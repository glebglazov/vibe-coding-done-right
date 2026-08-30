#!/bin/bash

# VCDR Release Build Script
# Archives, Developer ID-signs, notarizes and staples the app, then packages a DMG
# that launches on any Mac — not just the ones in a development provisioning profile.

set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-vcdr-notary}"
NOTARIZE=1

for arg in "$@"; do
    case "$arg" in
        --skip-notarization) NOTARIZE=0 ;;
        *) echo "Unknown option: $arg"; echo "Usage: $0 [--skip-notarization]"; exit 1 ;;
    esac
done
BUILD_DIR="$(mktemp -d)"
ARCHIVE="$BUILD_DIR/VCDR.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/VCDR.app"
DMG_OUTPUT="$HOME/Desktop/vcdr.dmg"
VOLNAME="VCDR"

trap 'rm -rf "$BUILD_DIR"' EXIT

# Archiving clears ONLY_ACTIVE_ARCH, so it would also build x86_64 — which FluidAudio
# does not compile for. The transcription path is ANE-optimized CoreML anyway, so an
# Intel slice would be dead weight even if it built.
echo "🔨 Archiving VCDR (arm64)..."
xcodebuild -scheme vcdr-mac -configuration Release -destination 'platform=macOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    -archivePath "$ARCHIVE" archive

echo ""
echo "✍️  Exporting with Developer ID signing..."
# -allowProvisioningUpdates authorizes xcodebuild to reach the developer portal and
# fetch the Developer ID profile. Without it, automatic signing fails from the CLI
# with "No profiles for ... were found" even when the certificate is installed.
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates

# An Apple Development signature or a lingering get-task-allow means the export
# silently fell back to a development identity, which is exactly the failure this
# script exists to prevent. Refuse to package it.
echo ""
echo "🔍 Verifying signature..."
# Captured into variables rather than piped into grep -q: under `set -o pipefail`, the
# early exit of grep -q sends SIGPIPE to codesign and the pipeline reports failure even
# when the pattern matched.
SIG_INFO=$(codesign -dvvv "$APP" 2>&1)
ENTITLEMENTS=$(codesign --display --entitlements - --xml "$APP" 2>/dev/null)

if ! printf '%s' "$SIG_INFO" | grep -q "Authority=Developer ID Application"; then
    echo "❌ Not signed with a Developer ID Application certificate."
    printf '%s\n' "$SIG_INFO" | grep "Authority=" || true
    exit 1
fi
if printf '%s' "$ENTITLEMENTS" | grep -q "get-task-allow"; then
    echo "❌ Export still carries get-task-allow (debug entitlement)."
    exit 1
fi
codesign --verify --strict --deep "$APP"
echo "✅ Developer ID signature verified"

# Notarize the app itself so the ticket travels with it once the user drags it out
# of the DMG. Stapling only the DMG would leave the installed copy needing an
# online Gatekeeper check on first launch.
if [ "$NOTARIZE" = 1 ]; then
    echo ""
    echo "📤 Notarizing app (this can take a few minutes)..."
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/VCDR.zip"
    xcrun notarytool submit "$BUILD_DIR/VCDR.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
else
    echo ""
    echo "⏭️  Skipping notarization (--skip-notarization)"
fi

# A drag-installable DMG needs the app and an /Applications symlink sitting side by
# side, plus a window layout that Finder records into the image's .DS_Store. Finder can
# only write that to a mounted read/write image, so build UDRW and compress afterwards.
echo ""
echo "💾 Creating DMG installer..."
STAGING="$BUILD_DIR/dmg-staging"
RW_DMG="$BUILD_DIR/VCDR-rw.dmg"

mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp dmg-assets/background.tiff "$STAGING/.background/background.tiff"

# The paired-resolution TIFF and the volume icon are committed under dmg-assets/ rather
# than generated here, so a release build needs nothing beyond Xcode.
cp dmg-assets/VolumeIcon.icns "$STAGING/.VolumeIcon.icns"

# A stale mount from an interrupted earlier run would make Finder lay out the wrong disk.
if [ -d "/Volumes/$VOLNAME" ]; then
    hdiutil detach "/Volumes/$VOLNAME" -force
fi

rm -f "$DMG_OUTPUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov \
    -format UDRW -fs HFS+ "$RW_DMG"

DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
    | grep '^/dev/' | head -1 | awk '{print $1}')
trap 'hdiutil detach "$DEV" -force >/dev/null 2>&1 || true; rm -rf "$BUILD_DIR"' EXIT

# Finder is the only thing that writes icon positions, so this drives it by Apple event.
# The terminal running this script needs Automation permission for Finder.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        set background picture of opts to file ".background:background.tiff"
        set position of item "VCDR.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

SetFile -a C "/Volumes/$VOLNAME"

sync
hdiutil detach "$DEV"
trap 'rm -rf "$BUILD_DIR"' EXIT

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUTPUT"

if [ "$NOTARIZE" = 1 ]; then
    echo ""
    echo "📤 Notarizing DMG..."
    xcrun notarytool submit "$DMG_OUTPUT" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_OUTPUT"

    echo ""
    echo "🔍 Final Gatekeeper assessment..."
    spctl -a -t open --context context:primary-signature -vv "$DMG_OUTPUT"

    echo ""
    echo "✅ Release build complete and notarized!"
    echo "📍 DMG Location: $DMG_OUTPUT"
    echo ""
    echo "📝 This DMG installs on any Mac running macOS 15.0+ with no Gatekeeper bypass."
else
    echo ""
    echo "✅ Release build complete (NOT notarized)"
    echo "📍 DMG Location: $DMG_OUTPUT"
    echo ""
    echo "📝 Developer ID-signed, so it is no longer locked to provisioned devices —"
    echo "   but Gatekeeper will still refuse the first launch on another Mac."
    echo "   macOS 15 dropped the Control-click bypass, so the recipient must use"
    echo "   System Settings > Privacy & Security > \"Open Anyway\"."
fi
