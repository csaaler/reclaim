#!/bin/bash
# Builds build/Reclaim.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

cd "$(dirname "$0")/.."
swift build -c "$CONFIG" --product ReclaimApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Reclaim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ReclaimApp" "$APP/Contents/MacOS/Reclaim"
cp Sources/ReclaimApp/Resources/Info.plist "$APP/Contents/Info.plist"

# The version comes from the latest vX.Y.Z tag, the build number from the commit count. Without
# git history (a source zip or a shallow clone) the placeholders in Info.plist stay.
TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [ -n "$TAG" ]; then
    plutil -replace CFBundleShortVersionString -string "${TAG#v}" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -p codesigning -v | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "WARNING: ad-hoc signed — Full Disk Access will need re-granting after each rebuild"
fi

codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"
