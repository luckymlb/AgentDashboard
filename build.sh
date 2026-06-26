#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AgentDashboard"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."
cd "$SCRIPT_DIR"
swift build

echo "Packaging .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Always copy from the canonical source
cp "$SCRIPT_DIR/AgentDashboard/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Done! App bundle at: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "To kill existing instance first:"
echo "  pkill -f AgentDashboard; open $APP_BUNDLE"
