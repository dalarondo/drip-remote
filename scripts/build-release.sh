#!/bin/bash
set -e

# Configuration
APP_NAME="Drip Remote"
VERSION=$(grep 'MARKETING_VERSION:' project.yml | sed 's/.*: *"\(.*\)"/\1/')
# Your "Developer ID Application: Name (TEAMID)" certificate. Without one, the app is signed
# ad hoc: it runs on this Mac, but other Macs will refuse to open it until it is notarized.
SIGNING_IDENTITY="${DRIP_SIGNING_IDENTITY:--}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
ARCHIVE_PATH="$DIST_DIR/DripRemote.xcarchive"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/DripRemote-$VERSION.dmg"

cd "$PROJECT_DIR"
mkdir -p "$DIST_DIR"

echo "==> Version: $VERSION"

# Generate Xcode project from project.yml
echo "==> Generating Xcode project..."
xcodegen generate

# Archive without signing (avoids profile conflicts with dependencies)
echo "==> Archiving..."
xcodebuild -project DripRemote.xcodeproj -scheme DripRemote -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

echo "==> Checking architectures..."
lipo -info "$ARCHIVE_APP/Contents/MacOS/$APP_NAME"

# Sign frameworks and dylibs first
echo "==> Signing with Developer ID..."
find "$ARCHIVE_APP" \( -name "*.framework" -o -name "*.dylib" \) | while read -r item; do
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$item"
done

# Sign the app bundle (hardened runtime, with the camera / microphone entitlements)
# (A secure timestamp needs a real certificate; ad hoc signatures go without.)
TIMESTAMP="--timestamp=none"
[ "$SIGNING_IDENTITY" != "-" ] && TIMESTAMP="--timestamp"
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGNING_IDENTITY" \
    --entitlements "$PROJECT_DIR/DripRemote/DripRemote.entitlements" \
    "$ARCHIVE_APP"

# Extract signed app
echo "==> Extracting app bundle..."
rm -rf "$APP_BUNDLE"
cp -R "$ARCHIVE_APP" "$APP_BUNDLE"
rm -rf "$ARCHIVE_PATH"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"

# Create DMG
echo "==> Creating DMG..."
rm -f "$DMG_PATH"
DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING"

if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "==> Signing DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

echo ""
echo "==> Build complete!"
echo "    App: $APP_BUNDLE"
echo "    DMG: $DMG_PATH"
echo ""
echo "To notarize, run:"
echo "    xcrun notarytool submit \"$DMG_PATH\" --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <APP_SPECIFIC_PASSWORD> --wait"
echo "    xcrun stapler staple \"$DMG_PATH\""
echo ""
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Signed ad hoc (no DRIP_SIGNING_IDENTITY set): fine on this Mac, blocked by Gatekeeper elsewhere."
    echo ""
fi
echo "To create a GitHub release:"
echo "    gh release create v$VERSION \"$DMG_PATH\" --title \"v$VERSION\" --generate-notes"
