#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="MacMeetSubscriber"
BUNDLE_ID="com.macmeetsubscriber.app"
VERSION="1.0.0"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_DIR="$SCRIPT_DIR/dist/$APP_NAME.app"

echo "=== Building $APP_NAME ==="

# 1. Build release binary
echo "[1/3] Compiling (release)..."
swift build -c release 2>&1 | tail -3

# 2. Create .app bundle (only if it doesn't exist yet)
if [ ! -d "$APP_DIR" ]; then
    echo "[2/3] Creating .app bundle..."
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"

    # Write Info.plist
    cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>$APP_NAME needs microphone access to record your voice during meetings.</string>
    <key>NSHumanReadableCopyright</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

    echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

    # Copy icon if exists
    ICNS="$SCRIPT_DIR/dist/MacMeetSubscriber.icns"
    if [ -f "$ICNS" ]; then
        cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
    fi

    # Sign the app (first time only — this establishes the identity for TCC)
    cp "$BUILD_DIR/MeetingRecorder" "$APP_DIR/Contents/MacOS/MeetingRecorder"
    echo "[3/3] Signing app (first time)..."
    codesign --force --deep --sign - "$APP_DIR"
else
    # Update only the binary, DO NOT re-sign to preserve TCC permissions
    echo "[2/3] Updating binary..."
    cp "$BUILD_DIR/MeetingRecorder" "$APP_DIR/Contents/MacOS/MeetingRecorder"
    echo "[3/3] Skipping re-sign (preserving TCC permissions)."
fi

echo ""
echo "=== Done ==="
echo "App: $APP_DIR"
echo ""
echo "Run:  open \"$APP_DIR\""
