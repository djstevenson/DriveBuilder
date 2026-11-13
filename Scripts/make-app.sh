#!/bin/bash
# Builds DriveBuilder Studio in release mode and wraps it in an .app bundle,
# so it can live in /Applications and launch without Xcode.
#
#   Scripts/make-app.sh [destination-directory]   (default: /Applications)
#
# The app still reads the telemetry database and Maps folder from this
# source tree (their paths are baked in at compile time), so keep the
# repository where it is, and re-run this script after pulling changes.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-/Applications}"
app="$destination/DriveBuilder Studio.app"

cd "$repo"
swift build -c release --product DriveBuilderStudio
bin="$(swift build -c release --show-bin-path)"

# Quit any running copy first, or the replaced bundle can misbehave.
osascript -e 'quit app "DriveBuilder Studio"' 2>/dev/null || true

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/DriveBuilderStudio" "$app/Contents/MacOS/"

# SPM's Bundle.module looks in Contents/Resources first. -c clones on APFS,
# so the 4.5 GB of OS data doesn't take up a second copy's worth of disk.
for bundle in "$bin"/*.bundle; do
    cp -Rc "$bundle" "$app/Contents/Resources/" 2>/dev/null \
        || cp -R "$bundle" "$app/Contents/Resources/"
done

# The icon: Scripts/AppIcon/icon.svg rasterised into every size an
# .icns wants (needs rsvg-convert, from Homebrew's librsvg).
if command -v rsvg-convert >/dev/null; then
    iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir "$iconset"
    for size in 16 32 128 256 512; do
        rsvg-convert -w $size -h $size Scripts/AppIcon/icon.svg -o "$iconset/icon_${size}x${size}.png"
        rsvg-convert -w $((size * 2)) -h $((size * 2)) Scripts/AppIcon/icon.svg -o "$iconset/icon_${size}x${size}@2x.png"
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$iconset")"
else
    echo "rsvg-convert not found (brew install librsvg): building without an icon" >&2
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DriveBuilderStudio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.djstevenson.DriveBuilderStudio</string>
    <key>CFBundleName</key>
    <string>DriveBuilder Studio</string>
    <key>CFBundleDisplayName</key>
    <string>DriveBuilder Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app to run on this Mac.
codesign --force --sign - "$app"

echo "Built $app"
