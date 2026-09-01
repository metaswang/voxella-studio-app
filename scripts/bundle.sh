#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign
#   scripts/bundle.sh debug --sign              # Apple Development + profile (native SIWA)
#   scripts/bundle.sh release --sign            # codesign with SIGNING_IDENTITY + profile
#   scripts/bundle.sh release --dist            # Developer ID + notarize + staple + DMG

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

ENV_FILE=".env"
if [ "$CONFIG" = "release" ] && [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE=".env.prod"
fi
if [ -f "$ROOT/$ENV_FILE" ]; then
  echo "==> Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/$ENV_FILE"
  set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
RESOURCES="$ROOT/Sources/PalmierPro/Resources"
ENTITLEMENTS_TEMPLATE="$ROOT/scripts/PalmierPro.entitlements"
DEBUG_ENTITLEMENTS="$ROOT/scripts/PalmierPro.debug.entitlements"
APP="$ROOT/.build/VoxStudio.app"
ZIP="$ROOT/.build/VoxStudio.zip"
DMG="$ROOT/.build/VoxStudio.dmg"

echo "==> Building ($CONFIG)"
TRAITS="BundledSpeech"
BUILD_ARGS=(-c "$CONFIG" --traits "$TRAITS")
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/VoxStudio"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/VoxStudio"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

inject_plist() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    echo "!! $key not set in $ENV_FILE — Settings → Models will be unavailable" >&2
    return
  fi
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
}

echo "==> Injecting backend config into Info.plist"
inject_plist PalmierConvexDeploymentURL "${CONVEX_DEPLOYMENT_URL:-}"
inject_plist PalmierConvexHttpURL "${CONVEX_HTTP_URL:-}"
inject_plist GIDClientID "${GOOGLE_MAC_CLIENT_ID:-}"
inject_plist GIDServerClientID "${GOOGLE_SERVER_CLIENT_ID:-}"
if [ -n "${GOOGLE_MAC_REVERSED_CLIENT_ID:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 ${GOOGLE_MAC_REVERSED_CLIENT_ID}" "$APP/Contents/Info.plist"
else
  echo "!! GOOGLE_MAC_REVERSED_CLIENT_ID not set in $ENV_FILE — Google Sign-In callback will be unavailable" >&2
fi

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

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VoxStudio"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Ad-hoc signing main app (no timestamp, no helpers)"
  echo "!! Ad-hoc builds use the login keychain and may request access after a rebuild." >&2
  codesign --force --options runtime --entitlements "$DEBUG_ENTITLEMENTS" --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

DSYM="$ROOT/.build/VoxStudio.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/VoxStudio" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  echo "!! Ad-hoc builds use the login keychain and may request access after a rebuild." >&2
  codesign --force --deep --options runtime --entitlements "$DEBUG_ENTITLEMENTS" --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

if [ -z "$SIGNING_IDENTITY" ]; then
  echo "!! SIGNING_IDENTITY is required for --sign or --dist" >&2
  exit 1
fi

if [ "$MODE" = "dist" ] && [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "!! --dist requires a Developer ID Application identity; got: $SIGNING_IDENTITY" >&2
  exit 1
fi

cert_ou="$(
  security find-certificate -p -c "$SIGNING_IDENTITY" |
    openssl x509 -noout -subject |
    sed -n 's/.*OU=\([A-Za-z0-9]\{10\}\).*/\1/p'
)"
if [[ ! "$cert_ou" =~ ^[A-Za-z0-9]{10}$ ]]; then
  echo "!! Could not read Team ID (OU) from SIGNING_IDENTITY: $SIGNING_IDENTITY" >&2
  exit 1
fi

TEAM_IDENTIFIER="${TEAM_IDENTIFIER:-$cert_ou}"
if [[ ! "$TEAM_IDENTIFIER" =~ ^[A-Za-z0-9]{10}$ ]]; then
  echo "!! TEAM_IDENTIFIER is not a valid 10-character Team ID" >&2
  exit 1
fi
if [ "$TEAM_IDENTIFIER" != "$cert_ou" ]; then
  echo "!! TEAM_IDENTIFIER=$TEAM_IDENTIFIER does not match certificate OU=$cert_ou" >&2
  echo "!! Native Sign in with Apple requires the paid team that owns com.voxella.studio" >&2
  exit 1
fi

PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE/#\~/$HOME}"
if [ -z "$PROVISIONING_PROFILE" ]; then
  echo "!! PROVISIONING_PROFILE is required for --sign or --dist (restricted entitlements)" >&2
  exit 1
fi
if [ ! -f "$PROVISIONING_PROFILE" ]; then
  echo "!! provisioning profile not found: $PROVISIONING_PROFILE" >&2
  exit 1
fi

PROFILE_PLIST="$(mktemp -t palmierpro-profile)"
SIGNING_ENTITLEMENTS="$(mktemp -t palmierpro-entitlements)"
trap 'rm -f "$PROFILE_PLIST" "$SIGNING_ENTITLEMENTS"' EXIT
security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
if [ "$profile_team" != "$TEAM_IDENTIFIER" ]; then
  echo "!! provisioning profile team $profile_team does not match $TEAM_IDENTIFIER" >&2
  exit 1
fi
if [ "$profile_app_id" != "$TEAM_IDENTIFIER.com.voxella.studio" ]; then
  echo "!! provisioning profile application-identifier is $profile_app_id" >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.applesignin:0' "$PROFILE_PLIST" >/dev/null 2>&1; then
  echo "!! provisioning profile is missing com.apple.developer.applesignin" >&2
  exit 1
fi

host_udid="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/{print $2; exit}')"
if [ -n "$host_udid" ]; then
  if ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" | grep -q "$host_udid"; then
    echo "!! provisioning profile does not include this Mac's Provisioning UDID ($host_udid)" >&2
    echo "!! Apple Silicon uses Provisioning UDID, not Hardware UUID" >&2
    exit 1
  fi
fi

echo "==> Embedding provisioning profile"
cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"

sed "s/__TEAM_IDENTIFIER__/$TEAM_IDENTIFIER/g" \
  "$ENTITLEMENTS_TEMPLATE" > "$SIGNING_ENTITLEMENTS"

echo "==> Codesigning main app ($SIGNING_IDENTITY / $TEAM_IDENTIFIER)"
CODESIGN_ARGS=(--force --options runtime --entitlements "$SIGNING_ENTITLEMENTS" --sign "$SIGNING_IDENTITY")
if [ "$MODE" = "dist" ]; then
  CODESIGN_ARGS+=(--timestamp)
else
  CODESIGN_ARGS+=(--timestamp=none)
fi
codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

signed_team="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if [ "$signed_team" != "$TEAM_IDENTIFIER" ]; then
  echo "!! signed TeamIdentifier=$signed_team, expected $TEAM_IDENTIFIER" >&2
  exit 1
fi
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.developer.applesignin'; then
  echo "!! signed app is missing com.apple.developer.applesignin" >&2
  exit 1
fi

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized; native Sign in with Apple enabled)"
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
cp -R "$APP" "$STAGING/VoxStudio.app"
ln -s /Applications "$STAGING/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
hdiutil create \
  -volname "VoxStudio" \
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
