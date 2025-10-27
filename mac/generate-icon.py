#!/usr/bin/env python3

"""
VCDR Icon Generator
Creates a simple app icon with "vcdr" text in a monospace/hacker font style
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("❌ Error: Pillow library not found")
    print("📦 Install with: pip3 install Pillow")
    sys.exit(1)

def create_icon(size, output_path):
    """Create a single icon at the specified size"""
    # Create image with dark background
    img = Image.new('RGB', (size, size), color='#0a0a0a')
    draw = ImageDraw.Draw(img)

    # Try to use a monospace font (common on macOS)
    font_size = int(size * 0.35)  # Font size scales with icon size

    # Try different monospace fonts available on macOS
    font_paths = [
        '/System/Library/Fonts/Menlo.ttc',
        '/System/Library/Fonts/Monaco.dfont',
        '/System/Library/Fonts/Courier New.ttf',
        '/Library/Fonts/Courier New.ttf',
    ]

    font = None
    for font_path in font_paths:
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, font_size)
                print(f"✅ Using font: {font_path}")
                break
            except:
                continue

    if font is None:
        print("⚠️  Using default font (monospace fonts not found)")
        font = ImageFont.load_default()

    # Text to draw
    text = "vcdr"

    # Get text bounding box
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]

    # Calculate position to center text
    x = (size - text_width) // 2
    y = (size - text_height) // 2 - bbox[1]  # Adjust for bbox offset

    # Draw text with green "matrix/hacker" color
    draw.text((x, y), text, fill='#00ff41', font=font)

    # Add a subtle border
    draw.rectangle([(2, 2), (size-3, size-3)], outline='#00ff41', width=3)

    # Save the image
    img.save(output_path, 'PNG')
    print(f"✅ Created {size}x{size} icon: {output_path}")

def main():
    """Generate all required icon sizes for macOS"""
    # Output directory
    icon_dir = "vcdr/Assets.xcassets/AppIcon.appiconset"

    if not os.path.exists(icon_dir):
        print(f"❌ Error: {icon_dir} not found")
        sys.exit(1)

    print("🎨 Generating VCDR app icons...")
    print("")

    # macOS icon sizes (all the standard sizes)
    icon_sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    for size, filename in icon_sizes:
        output_path = os.path.join(icon_dir, filename)
        create_icon(size, output_path)

    print("")
    print("✅ All icons generated successfully!")
    print("")
    print("📝 Next steps:")
    print("   1. Open vcdr.xcodeproj in Xcode")
    print("   2. Navigate to Assets.xcassets → AppIcon")
    print("   3. The icons should appear automatically")
    print("   4. Rebuild the app to see the new icon")
    print("")

if __name__ == "__main__":
    main()
