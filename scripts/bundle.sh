#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM
#   scripts/bundle.sh debug --sign              # signed Developer ID-compatible app (requires DEVELOPER_ID_PROVISIONING_PROFILE)
#   scripts/bundle.sh debug --mas               # development-signed MAS app for local StoreKit sandbox testing
#   scripts/bundle.sh release --sign            # signed Developer ID-compatible app
#   scripts/bundle.sh release --mas             # Mac App Store app + installer package
#   scripts/bundle.sh release --dist            # Developer ID + notarize + staple + DMG

CONFIG="release"
MODE="dev"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --mas)         MODE="mas" ;;
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
RESOURCES="$ROOT/Sources/VoxstudioPro/Resources"
DEBUG_ENTITLEMENTS="$ROOT/scripts/VoxStudio.debug.entitlements"
DEVELOPER_ID_ENTITLEMENTS="$ROOT/scripts/VoxStudio.developer-id.entitlements"
APP="$ROOT/.build/VoxStudio.app"
ZIP="$ROOT/.build/VoxStudio.zip"
DMG="$ROOT/.build/VoxStudio.dmg"

if [ "$MODE" = "mas" ]; then
  SIGNING_IDENTITY="${MAS_SIGNING_IDENTITY:-$SIGNING_IDENTITY}"
  ENTITLEMENTS_TEMPLATE="${MAS_ENTITLEMENTS_TEMPLATE:-$ROOT/scripts/VoxStudio.mas.entitlements}"
  if [ "$CONFIG" = "debug" ] && [ -n "${PROVISIONING_PROFILE:-}" ]; then
    PROVISIONING_PROFILE="$PROVISIONING_PROFILE"
  else
    PROVISIONING_PROFILE="${MAS_PROVISIONING_PROFILE:-${PROVISIONING_PROFILE:-}}"
  fi
fi

echo "==> Generating MCP UI and installable connectors"
python3 "$ROOT/scripts/sync-mcp-branding.py"
(cd "$ROOT/mcp-ui" && npm run check && npm run build)
python3 "$ROOT/scripts/package-mcpb.py"
python3 "$ROOT/scripts/package-openai-plugin.py" --output "$ROOT/.build/openai-plugin"
mkdir -p "$RESOURCES/OpenAIPlugin"
cp "$ROOT/.build/openai-plugin/VoxStudio-OpenAI-Plugin.zip" "$RESOURCES/OpenAIPlugin/"
echo "==> Building ($CONFIG)"
TRAITS="BundledSpeech"
if [ "$MODE" = "mas" ]; then
  TRAITS="$TRAITS,MacAppStore"
else
  TRAITS="$TRAITS,SparkleUpdates"
fi
BUILD_ARGS=(-c "$CONFIG" --traits "$TRAITS")

# SwiftPM invokes the Metal compiler for the app's CI kernels. Xcode ships
# this as an optional component, so fail early with the exact remediation
# instead of emitting one error per .metal source halfway through the build.
if ! xcrun -sdk macosx metal -v >/dev/null 2>&1; then
  echo "!! Metal Toolchain is not installed for the selected Xcode." >&2
  echo "!! Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi
python3 "$ROOT/scripts/build_metal.py" preflight

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
# SwiftPM hard-codes Bundle.main.bundleURL/<resource>.bundle. For a signed
# macOS app those bundles must live under Contents/Resources, so patch the
# generated accessors and rebuild them before assembling the app.
python3 "$ROOT/scripts/patch_swiftpm_bundle_accessors.py" "$BIN_DIR"
swift build "${BUILD_ARGS[@]}"
BIN="$BIN_DIR/VoxStudio"
SPARKLE_TOOLS="$ROOT/.build/sparkle-tools"
SPARKLE_SIGN_UPDATE="$SPARKLE_TOOLS/bin/sign_update"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/VoxStudio"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

PLIST_MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
BINARY_MINIMUM_SYSTEM_VERSION="$(otool -l "$APP/Contents/MacOS/VoxStudio" \
  | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/ && !printed{print $2; printed=1}')"
if [ "$PLIST_MINIMUM_SYSTEM_VERSION" != "$BINARY_MINIMUM_SYSTEM_VERSION" ]; then
  echo "!! deployment target mismatch: Info.plist=$PLIST_MINIMUM_SYSTEM_VERSION Mach-O=$BINARY_MINIMUM_SYSTEM_VERSION" >&2
  exit 1
fi
echo "==> Minimum macOS: $BINARY_MINIMUM_SYSTEM_VERSION"

if [ "$MODE" = "mas" ]; then
  for key in SUAutomaticallyUpdate SUEnableAutomaticChecks SUFeedURL SUPublicEDKey SUScheduledCheckInterval; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  done
fi

inject_plist() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    echo "!! $key not set in $ENV_FILE — Settings → Models will be unavailable" >&2
    return
  fi
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
}

inject_plist_bool() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    return
  fi
  if [ "$value" != "true" ] && [ "$value" != "false" ]; then
    echo "!! $key must be true or false" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$APP/Contents/Info.plist"
}

echo "==> Injecting backend config into Info.plist"
inject_plist PalmierConvexDeploymentURL "${CONVEX_DEPLOYMENT_URL:-}"
inject_plist PalmierConvexHttpURL "${CONVEX_HTTP_URL:-}"
inject_plist_bool VoxStudioPaidAccessEnabled "${VOXSTUDIO_PAID_ACCESS_ENABLED:-}"
if [ "$MODE" = "mas" ]; then
  if [ -z "${VOXSTUDIO_APP_STORE_LIFETIME_PRODUCT_ID:-}" ]; then
    echo "!! VOXSTUDIO_APP_STORE_LIFETIME_PRODUCT_ID is required for --mas" >&2
    exit 1
  fi
  inject_plist VoxStudioAppStoreLifetimeProductID "$VOXSTUDIO_APP_STORE_LIFETIME_PRODUCT_ID"
fi
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/VoxstudioPro_VoxstudioPro.bundle"
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

if [ -f "$RES_BUNDLE/StatusBarIcon.svg" ]; then
  cp "$RES_BUNDLE/StatusBarIcon.svg" "$APP/Contents/Resources/StatusBarIcon.svg"
else
  echo "!! missing StatusBarIcon.svg in SwiftPM resource bundle at $RES_BUNDLE" >&2
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

if [ -d "$RES_BUNDLE/KnowledgeSkills" ]; then
  cp -R "$RES_BUNDLE/KnowledgeSkills" "$APP/Contents/Resources/"
else
  echo "!! missing KnowledgeSkills/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Embed every SwiftPM resource bundle in the signed macOS resource directory.
# The main target's resources are also flattened into Contents/Resources above
# for existing Bundle.main lookups.
for runtime_bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$runtime_bundle" ] || continue
  bundle_name="$(basename "$runtime_bundle")"
  echo "==> Embedding SwiftPM runtime resource bundle: $bundle_name"
  cp -R "$runtime_bundle" "$APP/Contents/Resources/$bundle_name"
done

# YouTubeKit resolves meriyah/astring/yt_ejs through Bundle.module. Keep an
# explicit check for these critical resources so a packaging regression fails
# during assembly instead of crashing when a user imports a video.
YTKIT_BUNDLE="$(dirname "$BIN")/YouTubeKit_YouTubeKit.bundle"
if [ ! -d "$YTKIT_BUNDLE" ]; then
  echo "!! missing YouTubeKit_YouTubeKit.bundle at $YTKIT_BUNDLE" >&2
  exit 1
fi
for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  if [ ! -f "$APP/Contents/Resources/YouTubeKit_YouTubeKit.bundle/$resource" ]; then
    echo "!! YouTubeKit resource bundle is missing $resource" >&2
    exit 1
  fi
done

# Always evaluate the compiler/source/target cache, including CI kernels that
# SwiftPM may have cached under an older toolchain. One library serves M1–M4.
METAL_DIR="$ROOT/.build/metal/$CONFIG"
python3 "$ROOT/scripts/build_metal.py" prepare --output "$METAL_DIR"
for source in "$ROOT"/Metal/*.metal; do
  name="$(basename "$source" .metal).metallib"
  cp "$METAL_DIR/$name" "$APP/Contents/Resources/$name"
done
mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
cp "$METAL_DIR/mlx.metallib" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
cp "$METAL_DIR/metal-build.json" "$APP/Contents/Resources/metal-build.json"
python3 "$ROOT/scripts/verify_metal.py" "$APP"

echo "==> Clearing extended attributes before signing"
# SwiftPM checks out package resources read-only. Normalize owner write access
# on the assembled app so xattr can remove quarantine/resource attributes before
# codesign seals the bundle.
chmod -R u+rwX "$APP"
xattr -cr "$APP"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VoxStudio"

if [ "$MODE" != "mas" ]; then
  echo "==> Embedding Sparkle.framework for in-app updates"
  SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
  if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "!! Sparkle.framework not found in $BIN_DIR" >&2
    exit 1
  fi
  cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
  if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    echo "!! Failed to copy Sparkle.framework into app bundle" >&2
    exit 1
  fi
  echo "==> Clearing extended attributes on Sparkle.framework"
  xattr -cr "$APP/Contents/Frameworks/Sparkle.framework"
fi

touch "$APP"

ensure_sparkle_tools() {
  if [ -x "$SPARKLE_SIGN_UPDATE" ]; then
    return
  fi
  mkdir -p "$SPARKLE_TOOLS"
  local archive="$ROOT/.build/Sparkle-2.9.2.tar.xz"
  echo "==> Downloading Sparkle 2.9.2 tools for appcast signing"
  curl -L --fail --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz" \
    -o "$archive"
  tar -xJf "$archive" -C "$SPARKLE_TOOLS"
  if [ ! -x "$SPARKLE_SIGN_UPDATE" ] && [ -x "$SPARKLE_TOOLS/Sparkle.framework/Versions/Current/../../../bin/sign_update" ]; then
    SPARKLE_SIGN_UPDATE="$SPARKLE_TOOLS/bin/sign_update"
  fi
  if [ ! -x "$SPARKLE_SIGN_UPDATE" ]; then
    echo "!! Sparkle sign_update is still missing after download" >&2
    ls -la "$SPARKLE_TOOLS" >&2 || true
    exit 1
  fi
}

if [ "$MODE" = "fast" ]; then
  echo "==> Ad-hoc signing main app (no timestamp)"
  echo "!! Ad-hoc builds use an isolated in-memory credential store and do not access production Keychain items." >&2
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
  echo "!! Ad-hoc builds use an isolated in-memory credential store and do not access production Keychain items." >&2
  codesign --force --options runtime --entitlements "$DEBUG_ENTITLEMENTS" --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

if [ -z "$SIGNING_IDENTITY" ]; then
  echo "!! SIGNING_IDENTITY is required for --sign or --dist" >&2
  exit 1
fi

if [ "$MODE" = "mas" ] && [[ "$SIGNING_IDENTITY" != 3rd\ Party\ Mac\ Developer\ Application:* ]]; then
  echo "!! --mas requires a 3rd Party Mac Developer Application identity; got: $SIGNING_IDENTITY" >&2
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
  exit 1
fi

EXPECTED_APP_ID="$TEAM_IDENTIFIER.com.voxella.studio"
EXPECTED_ACCESS_GROUP="$TEAM_IDENTIFIER.com.voxella.studio"

if [ "$MODE" = "mas" ]; then
  PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
  PROVISIONING_PROFILE="${PROVISIONING_PROFILE/#\~/$HOME}"
  if [ -z "$PROVISIONING_PROFILE" ]; then
    echo "!! MAS_PROVISIONING_PROFILE is required for --mas" >&2
    exit 1
  fi
elif [ "$MODE" = "sign" ] || [ "$MODE" = "dist" ]; then
  # `--sign` and `--dist` must keep the same Developer ID designated
  # requirement as the distributed app. Falling back to the local Apple
  # Development profile makes TCC grants (Screen Recording, Microphone, etc.)
  # look enabled in System Settings while remaining unusable by this build.
  PROVISIONING_PROFILE="${DEVELOPER_ID_PROVISIONING_PROFILE:-}"
  PROVISIONING_PROFILE="${PROVISIONING_PROFILE/#\~/$HOME}"
  ENTITLEMENTS_TEMPLATE="${ENTITLEMENTS_TEMPLATE:-$DEVELOPER_ID_ENTITLEMENTS}"
  if [ -z "$PROVISIONING_PROFILE" ]; then
    echo "!! DEVELOPER_ID_PROVISIONING_PROFILE is required for --sign/--dist so Keychain access groups can be authorized" >&2
    exit 1
  fi
fi

if [ -z "$PROVISIONING_PROFILE" ]; then
  echo "!! provisioning profile is required" >&2
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
profile_access_group="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "$PROFILE_PLIST" 2>/dev/null || true)"
if [ "$profile_team" != "$TEAM_IDENTIFIER" ]; then
  echo "!! provisioning profile team $profile_team does not match $TEAM_IDENTIFIER" >&2
  exit 1
fi
if [ "$profile_app_id" != "$EXPECTED_APP_ID" ]; then
  echo "!! provisioning profile application-identifier is $profile_app_id, expected $EXPECTED_APP_ID" >&2
  exit 1
fi
if [ "$profile_access_group" != "$EXPECTED_ACCESS_GROUP" ] \
    && [ "$profile_access_group" != "$TEAM_IDENTIFIER.*" ]; then
  echo "!! provisioning profile keychain-access-groups[0] is ${profile_access_group:-missing}, expected $EXPECTED_ACCESS_GROUP or $TEAM_IDENTIFIER.*" >&2
  exit 1
fi

profile_certificate="$(
  security cms -D -i "$PROVISIONING_PROFILE" |
    plutil -extract DeveloperCertificates.0 raw -o - - |
    base64 --decode |
    openssl x509 -inform DER -noout -subject -nameopt RFC2253 |
    awk -F, '{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^CN=/) {
          sub(/^CN=/, "", $i)
          print $i
          exit
        }
      }
    }'
)"
if [ -z "$profile_certificate" ]; then
  echo "!! could not determine the signing certificate from $PROVISIONING_PROFILE" >&2
  exit 1
fi

# A Developer ID build must never silently switch to an Apple Development
# identity. Besides invalidating existing TCC grants, it no longer represents
# the signing mode requested by `--sign` / `--dist`.
if { [ "$MODE" = "sign" ] || [ "$MODE" = "dist" ]; } \
    && [[ "$profile_certificate" != Developer\ ID\ Application:* ]]; then
  echo "!! $MODE requires a Developer ID Application provisioning profile; got: $profile_certificate" >&2
  echo "!! set DEVELOPER_ID_PROVISIONING_PROFILE to the matching Developer ID profile" >&2
  exit 1
fi

# A debug MAS build may intentionally use an Apple Development profile for
# local StoreKit sandbox testing. Match that profile's certificate rather than
# combining it with the distribution identity from .env.
if [ "$CONFIG" = "debug" ] && [ "$MODE" = "mas" ] \
    && [[ "$profile_certificate" == Apple\ Development:* ]]; then
  if ! security find-certificate -p -c "$profile_certificate" >/dev/null 2>&1; then
    echo "!! profile certificate is not installed in the login keychain: $profile_certificate" >&2
    exit 1
  fi
  echo "==> Using profile-bound development identity: $profile_certificate"
  SIGNING_IDENTITY="$profile_certificate"
fi
if [ "$profile_certificate" != "$SIGNING_IDENTITY" ]; then
  echo "!! provisioning profile is bound to $profile_certificate, but the selected signing identity is $SIGNING_IDENTITY" >&2
  echo "!! use a matching profile/certificate pair; do not mix Developer ID and Apple Development/MAS signing." >&2
  exit 1
fi

echo "==> Embedding provisioning profile"
cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
chmod 644 "$APP/Contents/embedded.provisionprofile"
sed "s/__TEAM_IDENTIFIER__/$TEAM_IDENTIFIER/g" \
  "$ENTITLEMENTS_TEMPLATE" > "$SIGNING_ENTITLEMENTS"

# The downloaded provisioning profile can carry quarantine/metadata xattrs.
echo "==> Clearing extended attributes after embedding provisioning profile"
xattr -cr "$APP"

echo "==> Codesigning main app ($SIGNING_IDENTITY / $TEAM_IDENTIFIER)"
if [ "$MODE" = "mas" ]; then
  bash scripts/check-mas-billing.sh "$APP"
fi

# Sign Sparkle.framework inside-out before signing the app
if [ "$MODE" != "mas" ] && [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "==> Codesigning Sparkle.framework"
  # Sign XPCServices if present
  if [ -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ]; then
    for xpc in "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc; do
      if [ -e "$xpc" ]; then
        echo "    Signing $(basename "$xpc")"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$xpc"
      fi
    done
  fi
  # Sparkle's updater helpers have their own signatures and must be signed
  # directly with Developer ID and a secure timestamp for notarization.
  UPDATER_APP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  UPDATER_BINARY="$UPDATER_APP/Contents/MacOS/Updater"
  if [ -f "$UPDATER_BINARY" ]; then
    echo "    Signing Updater.app/Contents/MacOS/Updater"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$UPDATER_BINARY"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$UPDATER_APP"
  fi
  AUTOUPDATE_BINARY="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  if [ -f "$AUTOUPDATE_BINARY" ]; then
    echo "    Signing Autoupdate"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$AUTOUPDATE_BINARY"
  fi
  # Sign the framework itself
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework"
fi

CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --entitlements "$SIGNING_ENTITLEMENTS")
if [ "$MODE" != "mas" ]; then
  CODESIGN_ARGS+=(--options runtime)
fi
if [ "$MODE" = "dist" ]; then
  CODESIGN_ARGS+=(--timestamp)
else
  CODESIGN_ARGS+=(--timestamp=none)
fi
codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

signed_team="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if [ "$signed_team" != "$TEAM_IDENTIFIER" ]; then
  echo "!! signed TeamIdentifier=$signed_team, expected $TEAM_IDENTIFIER" >&2
  exit 1
fi

SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
if ! printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q '<key>keychain-access-groups</key>'; then
  echo "!! signed app is missing keychain-access-groups" >&2
  exit 1
fi
if ! printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q "$EXPECTED_ACCESS_GROUP"; then
  echo "!! signed keychain-access-groups does not include $EXPECTED_ACCESS_GROUP" >&2
  exit 1
fi
if ! printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q "$EXPECTED_APP_ID"; then
  echo "!! signed application-identifier does not match $EXPECTED_APP_ID" >&2
  exit 1
fi
if [ "$MODE" != "mas" ]; then
  if printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q 'com.apple.developer.applesignin'; then
    echo "!! Developer ID builds must not contain Apple sign-in entitlements" >&2
    exit 1
  fi
fi
if [ "$MODE" = "mas" ] && ! printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q 'com.apple.developer.applesignin'; then
  echo "!! signed MAS app is missing com.apple.developer.applesignin" >&2
  exit 1
fi
if [ ! -e "$APP/Contents/embedded.provisionprofile" ]; then
  echo "!! signed app is missing embedded.provisionprofile" >&2
  exit 1
fi
if [ "$MODE" = "mas" ]; then
  if [ -e "$APP/Contents/Frameworks/Sparkle.framework" ] \
      || otool -L "$APP/Contents/MacOS/VoxStudio" | grep -q Sparkle; then
    echo "!! Mac App Store builds must not embed or link Sparkle" >&2
    exit 1
  fi
else
  if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    echo "!! Direct distribution builds require Sparkle.framework in Frameworks/" >&2
    exit 1
  fi
  if ! otool -L "$APP/Contents/MacOS/VoxStudio" | grep -q Sparkle; then
    echo "!! Direct distribution builds must link Sparkle" >&2
    exit 1
  fi
fi
if [ "$MODE" = "mas" ]; then
  for key in SUAutomaticallyUpdate SUEnableAutomaticChecks SUFeedURL SUPublicEDKey SUScheduledCheckInterval; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
      echo "!! Mac App Store builds must not contain $key" >&2
      exit 1
    fi
  done
else
  for key in SUFeedURL SUPublicEDKey; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
      echo "!! Developer ID builds require $key" >&2
      exit 1
    fi
  done
fi

if [ "$MODE" = "sign" ] || [ "$MODE" = "mas" ]; then
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

SPARKLE_SIGNATURE=""
if [ "${SPARKLE_SIGN_UPDATE_REQUIRED:-1}" = "1" ]; then
  ensure_sparkle_tools
  echo "==> Signing DMG for existing Sparkle appcast clients"
  SPARKLE_SIGNATURE="$("$SPARKLE_SIGN_UPDATE" "$DMG")"
fi

echo ""
echo "==> Done"
echo "   App: $APP"
echo "   DMG: $DMG"
echo "   $SPARKLE_SIGNATURE"
echo ""
