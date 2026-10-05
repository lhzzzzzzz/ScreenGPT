#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build"
APP_PATH="$DIST_DIR/ScreenGPT.app"
STAGING_DIR="$BUILD_DIR/package-staging"
ZIP_PATH="$DIST_DIR/ScreenGPT-macOS.zip"
DMG_PATH="$DIST_DIR/ScreenGPT-macOS.dmg"

"$ROOT_DIR/scripts/build.sh"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/ScreenGPT.app"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID-signed build; set SIGNING_IDENTITY." >&2
    exit 2
  fi
  NOTARY_ZIP="$BUILD_DIR/ScreenGPT-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  ditto "$APP_PATH" "$STAGING_DIR/ScreenGPT.app"
fi

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
hdiutil create -volname "ScreenGPT" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi
rm -rf "$STAGING_DIR"
echo "Created $ZIP_PATH and $DMG_PATH"
