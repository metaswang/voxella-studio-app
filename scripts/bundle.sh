#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG

CONFIG="release"
MODE="dev"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
RESOURCES="$ROOT/Sources/PalmierPro/Resources"
ENTITLEMENTS="$ROOT/scripts/PalmierPro.entitlements"
APP="$ROOT/.build/Voxella Studio.app"
ZIP="$ROOT/.build/Voxella-Studio.zip"
DMG="$ROOT/.build/Voxella-Studio.dmg"

echo "==> Building ($CONFIG)"
TRAITS="BundledSpeech"
BUILD_ARGS=(-c "$CONFIG" --traits "$TRAITS")
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PalmierPro"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/VoxellaStudio"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/PalmierPro_PalmierPro.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if [ -f "$RES_BUNDLE/AppIcon.png" ]; then
  cp "$RES_BUNDLE/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
else
  echo "!! missing AppIcon.png in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
# .lproj folders must live at the bundle root for macOS to resolve them —
# flatten out of Resources/Localization/ even though that's just an org folder.
if [ -d "$RES_BUNDLE/Localization" ]; then
  for locale_dir in "$RES_BUNDLE/Localization"/*.lproj; do
    [ -d "$locale_dir" ] && cp -R "$locale_dir" "$APP/Contents/Resources/"
  done
else
  echo "!! missing Localization/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Models" ]; then
  cp -R "$RES_BUNDLE/Models" "$APP/Contents/Resources/"
else
  echo "!! missing Models/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if ! ls "$RES_BUNDLE"/*.metallib >/dev/null 2>&1; then
  echo "!! no .metallib in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi
cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"

MLX_METALLIB="$ROOT/.build/$CONFIG/mlx.metallib"
if [ ! -f "$MLX_METALLIB" ]; then
  echo "==> Building MLX metallib ($CONFIG)"
  BUILD_DIR="$ROOT/.build" "$ROOT/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" "$CONFIG"
fi
if [ ! -f "$MLX_METALLIB" ]; then
  echo "!! missing $MLX_METALLIB — on-device speech features (VAD, speaker ID) would die silently" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
cp "$MLX_METALLIB" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VoxellaStudio"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Ad-hoc signing main app (no timestamp, no helpers)"
  echo "!! Ad-hoc builds use the login keychain and may request access after a rebuild." >&2
  codesign --force --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

DSYM="$ROOT/.build/Voxella-Studio.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/VoxellaStudio" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  echo "!! Ad-hoc builds use the login keychain and may request access after a rebuild." >&2
  codesign --force --deep --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

if [ -z "$SIGNING_IDENTITY" ]; then
  echo "!! SIGNING_IDENTITY is required for --sign or --dist" >&2
  exit 1
fi

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

echo "==> Zipping .app for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (this can take several minutes)"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Building DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/Voxella Studio.app"
ln -s /Applications "$STAGING/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
hdiutil create \
  -volname "Voxella Studio" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGING"

echo "==> Codesigning DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Submitting DMG to notary"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"

echo ""
echo "==> Done"
echo "   App: $APP"
echo "   DMG: $DMG"
echo ""
