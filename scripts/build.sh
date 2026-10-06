#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/ScreenGPT.app"
VERSION="0.2.1"
IDENTIFIER="io.github.screengpt.app"
ARCHS_INPUT="${ARCHS:-arm64 x86_64}"
ARCHS_INPUT="${ARCHS_INPUT//,/ }"
read -r -a ARCH_LIST <<< "$ARCHS_INPUT"

if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  echo "ARCHS must include arm64, x86_64, or both." >&2
  exit 2
fi
for arch in "${ARCH_LIST[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture '$arch'. Use arm64 and/or x86_64." >&2; exit 2 ;;
  esac
done

mkdir -p "$BUILD_DIR/ClangModuleCache" "$DIST_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ClangModuleCache"

# Render the application icon from the native drawing source.
swift "$ROOT_DIR/scripts/generate-icon.swift" "$ROOT_DIR"

BINARIES=()
for arch in "${ARCH_LIST[@]}"; do
  triple="$arch-apple-macosx14.0"
  # Separate SwiftPM build databases so switching architectures remains repeatable.
  scratch_dir="$BUILD_DIR/$arch"
  swift build --package-path "$ROOT_DIR" --scratch-path "$scratch_dir" --configuration release --triple "$triple"
  binary_dir="$(swift build --package-path "$ROOT_DIR" --scratch-path "$scratch_dir" --configuration release --triple "$triple" --show-bin-path)"
  binary="$binary_dir/ScreenGPT"
  if [[ ! -x "$binary" ]]; then
    echo "Expected executable was not produced: $binary" >&2
    exit 1
  fi
  BINARIES+=("$binary")
done

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_PATH/Contents/MacOS/ScreenGPT"
else
  lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/ScreenGPT"
fi

ditto "$ROOT_DIR/Resources" "$APP_PATH/Contents/Resources"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ScreenGPT</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ScreenGPT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>ScreenGPT captures the selected area of your screen so you can ask AI about it.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  echo "Signing with Developer ID identity: $SIGNING_IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  echo "Signing locally with an ad hoc signature; this build is not notarized or publicly trusted."
  codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
echo "Built $APP_PATH"
