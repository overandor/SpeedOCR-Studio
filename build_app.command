#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "🔨 Building SpeedOCR Studio GUI App..."
swift build -c release

APP_NAME="SpeedOCR Studio.app"
APP_DIR="$DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$DIR/.build/release/speedocr" "$MACOS_DIR/speedocr"

cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>speedocr</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.speedocr.studio</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SpeedOCR Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>SpeedOCR Studio requires Screen Recording permission to capture screen video and recognize text.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>SpeedOCR Studio requires Microphone permission to capture system audio.</string>
</dict>
</plist>
EOF

chmod +x "$MACOS_DIR/speedocr"
chmod +x "$DIR/run.command"

codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"

echo "✅ App bundle created & ad-hoc signed at: $APP_DIR"
echo "🚀 You can launch it by running: open '$APP_DIR'"

