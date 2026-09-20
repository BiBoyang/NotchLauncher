#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP_DIR="build/NotchLauncher.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/NotchLauncher" "$APP_DIR/Contents/MacOS/NotchLauncher"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR" >/dev/null

echo "OK: $(pwd)/$APP_DIR"
