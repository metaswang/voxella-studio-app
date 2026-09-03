#!/bin/bash
set -euo pipefail

# Build and package the native Sign in with Apple Mac App Store artifact.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
if [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE="$ROOT/.env.prod"
fi
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

TEAM_IDENTIFIER="${TEAM_IDENTIFIER:-}"
MAS_SIGNING_IDENTITY="${MAS_SIGNING_IDENTITY:-}"
MAS_INSTALLER_IDENTITY="${MAS_INSTALLER_IDENTITY:-}"
MAS_PROVISIONING_PROFILE="${MAS_PROVISIONING_PROFILE:-}"

if [ -z "$TEAM_IDENTIFIER" ]; then
  echo "!! TEAM_IDENTIFIER is required" >&2
  exit 1
fi
if [ -z "$MAS_SIGNING_IDENTITY" ]; then
  echo "!! MAS_SIGNING_IDENTITY is required" >&2
  exit 1
fi
if [ -z "$MAS_INSTALLER_IDENTITY" ]; then
  echo "!! MAS_INSTALLER_IDENTITY is required" >&2
  exit 1
fi
if [ -z "$MAS_PROVISIONING_PROFILE" ]; then
  echo "!! MAS_PROVISIONING_PROFILE is required" >&2
  exit 1
fi

MAS_PROVISIONING_PROFILE="${MAS_PROVISIONING_PROFILE/#\~/$HOME}"
if [ ! -f "$MAS_PROVISIONING_PROFILE" ]; then
  echo "!! provisioning profile not found: $MAS_PROVISIONING_PROFILE" >&2
  exit 1
fi

APP="$ROOT/.build/VoxStudio.app"
PKG="$ROOT/.build/VoxStudio.pkg"

echo "==> Building the Mac App Store app"
MAS_SIGNING_IDENTITY="$MAS_SIGNING_IDENTITY" \
TEAM_IDENTIFIER="$TEAM_IDENTIFIER" \
MAS_PROVISIONING_PROFILE="$MAS_PROVISIONING_PROFILE" \
MAS_ENTITLEMENTS_TEMPLATE="$ROOT/scripts/VoxStudio.mas.entitlements" \
  "$ROOT/scripts/bundle.sh" release --mas

echo "==> Building the signed installer package"
rm -f "$PKG"
productbuild \
  --component "$APP" /Applications \
  --sign "$MAS_INSTALLER_IDENTITY" \
  "$PKG"

echo "==> Verifying the Mac App Store artifacts"
codesign --verify --strict --verbose=2 "$APP"
pkgutil --check-signature "$PKG"

echo ""
echo "==> Done"
echo "   App: $APP"
echo "   Package: $PKG"
