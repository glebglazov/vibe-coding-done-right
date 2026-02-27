# Developer ID Signing & Notarization Plan

## Overview

Set up proper code signing with a Developer ID Application certificate so that VCDR can be distributed via DMG to other Macs without permission re-prompts on each update and without Gatekeeper warnings.

## Current State Analysis

- **Signing**: `CODE_SIGN_STYLE = Automatic`, team `R9G7S83AGV`
- **Certificate on machine**: Only "Apple Development: Gleb Glazov (4UYWX4GGY4)" — works for local Xcode builds only
- **No entitlements file**: The app uses `ENABLE_APP_SANDBOX = NO` but has no explicit entitlements
- **build-release.sh**: Uses `xcodebuild build` (not `archive`), no signing for distribution, no notarization
- **Bundle ID**: `glebglazov.vcdr`

### Why permissions reset on each DMG install

macOS TCC stores permissions keyed by the app's code signing requirement. With only an "Apple Development" certificate, the release build is effectively ad-hoc signed for distribution purposes — TCC falls back to CDHash identification, which changes every build. A stable Developer ID certificate produces a stable code signing requirement (`identifier "glebglazov.vcdr" and anchor apple generic and certificate leaf[subject.CN] = "Developer ID Application: ..."`), so TCC recognizes updates as the same app.

## Desired End State

- `build-release.sh` produces a signed, notarized DMG that:
  - Installs cleanly on any Mac without Gatekeeper warnings
  - Preserves TCC permissions (Accessibility, Microphone) across app updates
  - Can be verified with `spctl --assess --verbose`
- The Xcode project has a proper entitlements file for the hardened runtime

### How to verify:
1. `codesign -dvvv /Applications/vcdr.app` shows "Developer ID Application: Gleb Glazov" authority
2. `spctl --assess --verbose /Applications/vcdr.app` returns "accepted, source=Developer ID"
3. Installing a new build over an existing one does NOT re-prompt for Accessibility or Microphone permissions

## What We're NOT Doing

- App Store distribution (no need for App Store Connect, provisioning profiles, or review)
- Sparkle/auto-update framework (out of scope, can be added later)
- CI/CD pipeline (builds remain local via `build-release.sh`)

## Implementation Approach

Two phases: (1) Apple Developer Portal setup (manual, one-time), (2) update build script and project settings.

---

## Phase 1: Apple Developer Portal Setup (Manual)

### Overview
Create the Developer ID Application certificate and app-specific password for notarization. This is a one-time manual process.

### Steps:

#### 1. Verify Apple Developer Program membership
- Go to https://developer.apple.com/account
- Confirm the account with team ID `R9G7S83AGV` has an active membership
- If not enrolled, enroll at https://developer.apple.com/programs/enroll/ ($99/year)

#### 2. Create Developer ID Application certificate
- Go to https://developer.apple.com/account/resources/certificates/list
- Click "+" to create a new certificate
- Select **"Developer ID Application"** (under "Software" section)
- Follow the CSR flow:
  - Open Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority
  - Enter your email, select "Saved to disk", click Continue
  - Upload the `.certSigningRequest` file to the portal
- Download the `.cer` file and double-click to install in Keychain

#### 3. Verify certificate installed
Run:
```bash
security find-identity -v -p codesigning
```
Should now show:
```
"Developer ID Application: Gleb Glazov (R9G7S83AGV)"
```

#### 4. Create app-specific password for notarization
- Go to https://appleid.apple.com/account/manage > Sign-In and Security > App-Specific Passwords
- Generate a new password, name it "vcdr-notarytool"
- Store it in the Keychain for `notarytool`:
```bash
xcrun notarytool store-credentials "vcdr-notarize" \
  --apple-id "YOUR_APPLE_ID_EMAIL" \
  --team-id "R9G7S83AGV" \
  --password "APP_SPECIFIC_PASSWORD"
```

### Success Criteria:

#### Automated Verification:
- [ ] `security find-identity -v -p codesigning` lists "Developer ID Application: Gleb Glazov (R9G7S83AGV)"
- [ ] `xcrun notarytool store-credentials` completes without error

#### Manual Verification:
- [ ] Certificate visible in Keychain Access under "My Certificates"

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: Project & Build Script Changes

### Overview
Add an entitlements file for the hardened runtime, and rewrite `build-release.sh` to use `xcodebuild archive` + export + notarization + DMG signing.

### Changes Required:

#### 1. Create entitlements file
**File**: `vcdr/vcdr.entitlements` (new file)

The app needs hardened runtime (required for notarization) with exceptions for:
- `com.apple.security.device.audio-input` — microphone recording
- `com.apple.security.automation.apple-events` — accessibility/CGEvent tap
- `com.apple.security.cs.disable-library-validation` — FluidAudio loads CoreML models at runtime

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

> Note: `com.apple.security.automation.apple-events` is for AppleScript/Apple Events. CGEvent tap for accessibility doesn't use an entitlement — it requires the Accessibility permission granted by the user in System Settings. The hardened runtime doesn't block CGEvent tap as long as the user has granted accessibility access.

#### 2. Add entitlements reference to Xcode project
**File**: `vcdr.xcodeproj/project.pbxproj`

Add to both Debug and Release build configurations for the vcdr target:
```
CODE_SIGN_ENTITLEMENTS = vcdr/vcdr.entitlements;
ENABLE_HARDENED_RUNTIME = YES;
```

#### 3. Create ExportOptions.plist for archive export
**File**: `ExportOptions.plist` (new file, project root)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>R9G7S83AGV</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

#### 4. Rewrite build-release.sh
**File**: `build-release.sh`

```bash
#!/bin/bash

# VCDR Release Build Script
# Builds, signs with Developer ID, notarizes, and creates a DMG

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE_PATH="$SCRIPT_DIR/build/vcdr.xcarchive"
EXPORT_PATH="$SCRIPT_DIR/build/export"
DMG_OUTPUT="$HOME/Desktop/vcdr.dmg"
NOTARIZE_PROFILE="vcdr-notarize"

# Clean previous build artifacts
rm -rf "$SCRIPT_DIR/build"
mkdir -p "$SCRIPT_DIR/build"

echo "==> Archiving VCDR in Release mode..."
xcodebuild archive \
    -scheme vcdr \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=R9G7S83AGV

echo ""
echo "==> Exporting archive..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist"

APP_PATH="$EXPORT_PATH/vcdr.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Export failed, app not found at $APP_PATH"
    exit 1
fi

echo ""
echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature valid."

echo ""
echo "==> Creating DMG..."
rm -f "$DMG_OUTPUT"
hdiutil create -volname "VCDR" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_OUTPUT"

echo ""
echo "==> Signing DMG..."
codesign --sign "Developer ID Application" "$DMG_OUTPUT"

echo ""
echo "==> Submitting for notarization..."
xcrun notarytool submit "$DMG_OUTPUT" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

echo ""
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_OUTPUT"

echo ""
echo "==> Verifying final DMG..."
spctl --assess --type open --context context:primary-signature "$DMG_OUTPUT" && echo "    DMG accepted by Gatekeeper." || echo "    Warning: DMG not accepted by Gatekeeper"

echo ""
echo "==> Release build complete!"
echo "    DMG: $DMG_OUTPUT"
echo ""
echo "    To verify on another Mac:"
echo "      1. Copy DMG, open it, drag vcdr to /Applications"
echo "      2. First launch: grant Accessibility + Microphone"
echo "      3. Future updates: permissions should persist automatically"
```

### Success Criteria:

#### Automated Verification:
- [ ] `xcodebuild -scheme vcdr -configuration Release build` succeeds (project still builds)
- [ ] `./build-release.sh` completes all steps without error
- [ ] `codesign -dvvv build/export/vcdr.app 2>&1 | grep Authority` shows "Developer ID Application: Gleb Glazov"
- [ ] `spctl --assess --verbose build/export/vcdr.app` returns "accepted"
- [ ] DMG opens and contains vcdr.app

#### Manual Verification:
- [ ] On target MacBook: install from DMG, grant Accessibility + Microphone on first launch
- [ ] On target MacBook: install a second build from DMG over the first — no permission re-prompts
- [ ] On target MacBook: no Gatekeeper "unidentified developer" warning

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Testing Strategy

### On the build Mac:
1. Run `./build-release.sh` and verify it completes
2. Check `codesign -dvvv` output shows Developer ID authority
3. Check `spctl --assess` passes

### On the target MacBook:
1. Install v1 from DMG — grant all permissions, verify app works
2. Build v2 (change nothing meaningful), install from new DMG
3. Verify permissions are NOT re-requested
4. Verify app still works after update

## References

- Apple docs: [Developer ID](https://developer.apple.com/developer-id/)
- Apple docs: [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple docs: [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- Current build script: `build-release.sh`
- Current project config: `vcdr.xcodeproj/project.pbxproj`
