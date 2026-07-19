#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="$HOME/Applications/TokenBurn.app"
BIN_NAME="TokenBurn"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TokenBurn</string>
    <key>CFBundleIdentifier</key>
    <string>com.dethok.tokenburn</string>
    <key>CFBundleName</key>
    <string>TokenBurn</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
