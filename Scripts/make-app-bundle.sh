#!/bin/bash
# Wrap the release binary in a double-clickable .app.
# Command Line Tools are enough. This does not call xcodebuild.
# A universal binary needs both SDKs; otherwise the host architecture is used
# (arm64 on an M1 Mac with only Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! swift build -c release --arch arm64 --arch x86_64; then
  echo "Universal build unavailable; building for the host architecture."
  swift build -c release
fi
BIN="$(swift build -c release --show-bin-path)/ThreeSixtyView"
APP="dist/ThreeSixtyView.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ThreeSixtyView"
if [[ ! -f Resources/AppIcon.icns ]]; then
  ./Scripts/make-icns.sh
fi
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ThreeSixtyView</string>
  <key>CFBundleDisplayName</key><string>ThreeSixtyView</string>
  <key>CFBundleGetInfoString</key><string>Native macOS viewer &amp; exporter for single-fisheye 360° video (Kodak PixPro SP360 4K / Wideshoot). Look around, pick views, export reframed or 360 equirectangular MP4.</string>
  <key>CFBundleIdentifier</key><string>org.threesixtyview.app</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleExecutable</key><string>ThreeSixtyView</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>360 media</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
        <string>public.movie</string>
        <string>public.image</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF
echo "Built $APP"
