#!/bin/bash

# DynamicAI - Build and Run Script
set -e

APP_NAME="DynamicAI"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

echo "🔨 Building $APP_NAME..."
cd "$PROJECT_DIR"

# Build the project
xcodebuild -project DynamicAI.xcodeproj \
    -scheme DynamicAI \
    -configuration Debug \
    build \
    -quiet

# Find the built app (exclude Index.noindex)
APP_PATH=$(find "$DERIVED_DATA" -path "*/Build/Products/Debug/$APP_NAME.app" -not -path "*/Index.noindex/*" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Could not find built app. Build may have failed."
    exit 1
fi

EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"

if [ ! -f "$EXECUTABLE" ]; then
    echo "❌ Executable not found at: $EXECUTABLE"
    exit 1
fi

echo "✅ Build successful"
echo "🚀 Launching $APP_NAME..."

# Kill any existing instance
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

# Launch the executable directly (avoids codesign issues in dev)
"$EXECUTABLE" &

echo "✨ $APP_NAME is running!"
echo "   Press ⌘⌥Space to toggle the AI assistant"
echo "   Click the ✦ sparkles icon in menu bar for options"
