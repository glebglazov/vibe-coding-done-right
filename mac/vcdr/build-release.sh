#!/bin/bash

# VCDR Release Build Script
# Builds the app in Release mode and creates a DMG for distribution

set -e  # Exit on any error

echo "🔨 Building VCDR in Release mode..."
xcodebuild -scheme vcdr -configuration Release build

echo ""
echo "📦 Finding built app..."
BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData/vcdr-*/Build/Products/Release/vcdr.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$BUILT_APP" ]; then
    echo "❌ Error: Could not find built app"
    exit 1
fi

echo "✅ Found app at: $BUILT_APP"

echo ""
echo "💾 Creating DMG installer..."
DMG_OUTPUT="$HOME/Desktop/vcdr.dmg"

# Remove old DMG if it exists
rm -f "$DMG_OUTPUT"

# Create DMG
hdiutil create -volname "VCDR" -srcfolder "$BUILT_APP" -ov -format UDZO "$DMG_OUTPUT"

echo ""
echo "✅ Release build complete!"
echo ""
echo "📍 DMG Location: $DMG_OUTPUT"
echo "📍 App Location: $BUILT_APP"
echo ""
echo "📝 Distribution Notes:"
echo "   - The DMG contains an unsigned build (works on your Mac only)"
echo "   - Other users will need to right-click → Open to bypass Gatekeeper"
echo "   - Or run: xattr -cr /Applications/vcdr.app"
echo "   - For proper distribution, you need an Apple Developer certificate ($99/year)"
echo ""
