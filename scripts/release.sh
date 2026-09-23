#!/bin/bash
set -euo pipefail

# Usage: scripts/release.sh
#
# Default R2/Cloudflare publication:
#   1. Auto-bump the patch version from the Cloudflare appcast
#   2. Build, sign, notarize, staple, and Sparkle-sign the DMG
#   3. prepare → upload → verify → cache-check → promote → postcheck on R2
#
# First Cloudflare publication requires RELEASE_BOOTSTRAP=1.
# Hugging Face publication is retired. RELEASE_TARGET=github remains an
# explicit emergency path and is not the default.

if [ $# -ne 0 ]; then
  echo "usage: $0" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/PalmierPro/Resources/Info.plist"
APPCAST="$ROOT/appcast.xml"
DMG="$ROOT/.build/VoxStudio.dmg"
SPARKLE_ROOT="$ROOT/.build/sparkle-tools"
EXPECTED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
PUBLIC_APPCAST_URL="https://assets.voxstudio.me/downloads/voxstudio/appcast.xml"
if python3 -c 'import boto3' >/dev/null 2>&1; then
  R2_TOOL=(python3 "$ROOT/scripts/r2_release.py")
else
  R2_TOOL=(uv run --no-project --with boto3 python "$ROOT/scripts/r2_release.py")
fi
VERSION_TOOL=(uv run --no-project python "$ROOT/scripts/release_version.py")
RELEASE_TARGET="${RELEASE_TARGET:-r2}"
cd "$ROOT"

ensure_sparkle_tools() {
  if [ -x "$SPARKLE_ROOT/bin/generate_keys" ]; then
    return
  fi
  mkdir -p "$SPARKLE_ROOT"
  ARCHIVE="$ROOT/.build/Sparkle-2.9.2.tar.xz"
  curl -L --fail --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz" \
    -o "$ARCHIVE"
  tar -xJf "$ARCHIVE" -C "$SPARKLE_ROOT"
  if [ ! -x "$SPARKLE_ROOT/bin/generate_keys" ]; then
    echo "error: Sparkle generate_keys tool is unavailable" >&2
    exit 1
  fi
}

verify_sparkle_key() {
  ensure_sparkle_tools
  ACTUAL_PUBLIC_KEY="$("$SPARKLE_ROOT/bin/generate_keys" -p)"
  if [ "$ACTUAL_PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]; then
    echo "error: Sparkle signing key does not match SUPublicEDKey; restore the original private key" >&2
    exit 1
  fi
}

require_worktree_ok() {
  if ! git diff-index --quiet HEAD -- && [ "${RELEASE_INCLUDE_WORKTREE:-0}" != "1" ]; then
    echo "error: set RELEASE_INCLUDE_WORKTREE=1 to explicitly include pending work" >&2
    git status --short >&2
    exit 1
  fi
}

require_macos_15() {
  test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "15.0"
  rg -q 'platforms: \[\.macOS\(\.v15\)\]' "$ROOT/Package.swift"
}

if [ "$RELEASE_TARGET" = "huggingface" ]; then
  echo "error: Hugging Face publication is retired; the default R2 flow is the supported release path" >&2
  exit 1
fi

if [ "$RELEASE_TARGET" = "r2" ] || [ "$RELEASE_TARGET" = "dmg" ]; then
  DELIVERY_ARGS=(--delivery-mode "${RELEASE_DELIVERY_MODE:-cache}" --enable-archives)
  if [ "${RELEASE_DELIVERY_MODE:-cache}" = "origin" ]; then
    DELIVERY_ARGS+=(--origin-reason "${RELEASE_ORIGIN_REASON:-}")
  fi
  if [ "$RELEASE_TARGET" = "r2" ] && [ "${RELEASE_RESUME:-0}" = "1" ]; then
    RESUME_ARGS=(resume "${DELIVERY_ARGS[@]}")
    [ "${RELEASE_DRY_RUN:-0}" != "1" ] || RESUME_ARGS+=(--dry-run)
    [ "${RELEASE_PROMOTE:-1}" = "1" ] || RESUME_ARGS+=(--skip-promote)
    # Resume the staged, signed artifact without bumping or rebuilding it.
    exec "${R2_TOOL[@]}" "${RESUME_ARGS[@]}"
  fi
  require_worktree_ok
  require_macos_15
  verify_sparkle_key

  LIVE_APPCAST="$(mktemp -t voxstudio-appcast.XXXXXX).xml"
  NOTES_CLEAN=""
  BUILD_LOG=""
  cleanup() {
    [ -z "$LIVE_APPCAST" ] || rm -f "$LIVE_APPCAST"
    [ -z "$NOTES_CLEAN" ] || rm -f "$NOTES_CLEAN"
    [ -z "$BUILD_LOG" ] || rm -f "$BUILD_LOG"
  }
  trap cleanup EXIT

  FETCH_STATUS=0
  "${R2_TOOL[@]}" fetch-appcast --output "$LIVE_APPCAST" || FETCH_STATUS=$?
  BOOTSTRAP_ARGS=()
  if [ "$FETCH_STATUS" -eq 2 ]; then
    if [ "${RELEASE_BOOTSTRAP:-0}" != "1" ]; then
      echo "error: Cloudflare appcast is not published yet; set RELEASE_BOOTSTRAP=1 for the first R2 release" >&2
      exit 1
    fi
    : >"$LIVE_APPCAST"
    BOOTSTRAP_ARGS=(--bootstrap)
  elif [ "$FETCH_STATUS" -ne 0 ]; then
    echo "error: failed to read the Cloudflare appcast" >&2
    exit 1
  fi

  CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
  CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
  VERSION="$("${VERSION_TOOL[@]}" next --current "$CURRENT_VERSION" --current-build "$CURRENT_BUILD" --appcast "$LIVE_APPCAST" ${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"})"
  NEW_BUILD="$("${VERSION_TOOL[@]}" plan \
    --requested "$VERSION" \
    --current "$CURRENT_VERSION" \
    --current-build "$CURRENT_BUILD" \
    --appcast "$LIVE_APPCAST" \
    ${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"})"
  echo "==> R2 release: $CURRENT_VERSION ($CURRENT_BUILD) -> $VERSION ($NEW_BUILD)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

  if [ "$RELEASE_TARGET" = "dmg" ]; then
    SPARKLE_SIGN_UPDATE_REQUIRED=0 ./scripts/bundle.sh release --dist
    echo "==> Artifact ready for verification: $DMG"
    exit 0
  fi

  echo "==> Building signed + notarized DMG"
  BUILD_LOG="$(mktemp -t voxstudio-build.XXXXXX).log"
  ./scripts/bundle.sh release --dist 2>&1 | tee "$BUILD_LOG"
  SIG_LINE="$(grep -E 'edSignature="[^"]+".*length="[0-9]+"' "$BUILD_LOG" | tail -1)"
  SIGNATURE="$(echo "$SIG_LINE" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
  LENGTH="$(echo "$SIG_LINE" | sed -E 's/.*length="([0-9]+)".*/\1/')"
  if [ -z "$SIGNATURE" ] || ! [[ "$LENGTH" =~ ^[0-9]+$ ]]; then
    echo "error: couldn't extract Sparkle signature or numeric length from build output" >&2
    exit 1
  fi

  MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
  RUN_ARGS=(
    run
    --dmg "$DMG"
    --version "$VERSION"
    --build "$NEW_BUILD"
    --signature "$SIGNATURE"
    --minimum-system-version "$MINIMUM_SYSTEM_VERSION"
    "${DELIVERY_ARGS[@]}"
  )
  if [ "${RELEASE_DRY_RUN:-0}" = "1" ]; then
    RUN_ARGS+=(--dry-run)
  fi
  if [ "${RELEASE_PROMOTE:-1}" != "1" ]; then
    RUN_ARGS+=(--skip-promote)
  fi
  echo "==> Publishing to Cloudflare R2"
  "${R2_TOOL[@]}" "${RUN_ARGS[@]}"
  echo ""
  echo "==> Released $VERSION ($NEW_BUILD)"
  echo "    latest: https://assets.voxstudio.me/downloads/voxstudio/VoxStudio.dmg"
  echo "    appcast: $PUBLIC_APPCAST_URL"
  echo "    Sparkle length: $LENGTH"
  exit 0
fi

if [ "$RELEASE_TARGET" != "github" ]; then
  echo "error: unknown RELEASE_TARGET=$RELEASE_TARGET" >&2
  exit 1
fi

echo "==> Preflight"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "error: must be on main (got: $BRANCH)" >&2
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "error: working tree has uncommitted changes:" >&2
  git status --short >&2
  exit 1
fi

git fetch origin main --quiet
git fetch origin --tags --quiet
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "error: local main differs from origin/main. Push or pull first." >&2
  exit 1
fi

LIVE_APPCAST="$(mktemp -t palmier-appcast.XXXXXX).xml"
NOTES_CLEAN=""
BUILD_LOG=""
cleanup() {
  [ -z "$LIVE_APPCAST" ] || rm -f "$LIVE_APPCAST"
  [ -z "$NOTES_CLEAN" ] || rm -f "$NOTES_CLEAN"
  [ -z "$BUILD_LOG" ] || rm -f "$BUILD_LOG"
}
trap cleanup EXIT

FEED_URL="https://raw.githubusercontent.com/palmier-io/palmier-pro/main/appcast.xml"
curl --fail --silent --show-error --location "$FEED_URL" --output "$LIVE_APPCAST"
if ! cmp -s "$APPCAST" "$LIVE_APPCAST"; then
  echo "error: local appcast.xml differs from the published feed; sync it before releasing" >&2
  exit 1
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
VERSION="$(python3 "$ROOT/scripts/release_version.py" next \
  --current "$CURRENT_VERSION" \
  --appcast "$LIVE_APPCAST")"
TAG="$VERSION"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists locally" >&2
  exit 1
fi
if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin" >&2
  exit 1
fi
echo "==> Release version: $CURRENT_VERSION -> $VERSION (patch increment)"

verify_sparkle_key

echo "==> Generating release notes from commit log"
NOTES_CLEAN="$(mktemp -t palmier-release.XXXXXX).md"
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
{
  echo "## What's new"
  echo ""
  if [ -n "$LAST_TAG" ]; then
    git log --pretty=format:"- %s" "$LAST_TAG..HEAD"
    echo ""
  else
    echo "First release."
  fi
} >"$NOTES_CLEAN"
echo "    (edit on GitHub later if you want to polish)"

echo "==> Bumping version"
if ! NEW_BUILD="$(python3 "$ROOT/scripts/release_version.py" plan \
    --requested "$VERSION" \
    --current "$CURRENT_VERSION" \
    --current-build "$CURRENT_BUILD" \
    --appcast "$LIVE_APPCAST")"; then
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "    $VERSION (build $NEW_BUILD)"

echo "==> Building signed + notarized DMG"
BUILD_LOG="$(mktemp -t palmier-build.XXXXXX).log"
./scripts/bundle.sh release --dist 2>&1 | tee "$BUILD_LOG"

SIG_LINE="$(grep -E 'edSignature="[^"]+".*length="[0-9]+"' "$BUILD_LOG" | tail -1)"
SIGNATURE="$(echo "$SIG_LINE" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
LENGTH="$(echo "$SIG_LINE" | sed -E 's/.*length="([0-9]+)".*/\1/')"
if [ -z "$SIGNATURE" ] || ! [[ "$LENGTH" =~ ^[0-9]+$ ]]; then
  echo "error: couldn't extract Sparkle signature or numeric length from build output" >&2
  echo "  got SIGNATURE=$SIGNATURE" >&2
  echo "  got LENGTH=$LENGTH" >&2
  exit 1
fi

echo "==> Committing + pushing version bump"
git add "$PLIST"
git commit -m "[build] Set version $VERSION"
git push origin main

echo "==> Tagging $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "==> Creating GH release"
gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$NOTES_CLEAN"

echo "==> Updating appcast.xml"
PUBDATE="$(date -R)"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
export VERSION NEW_BUILD PUBDATE LENGTH SIGNATURE MINIMUM_SYSTEM_VERSION
python3 <<'PYEOF'
import os
v = os.environ["VERSION"]
b = os.environ["NEW_BUILD"]
d = os.environ["PUBDATE"]
l = os.environ["LENGTH"]
s = os.environ["SIGNATURE"]
minimum_system_version = os.environ["MINIMUM_SYSTEM_VERSION"]
url = f"https://github.com/palmier-io/palmier-pro/releases/download/{v}/VoxStudio.dmg"

item = f"""        <item>
            <title>Version {v}</title>
            <pubDate>{d}</pubDate>
            <sparkle:version>{b}</sparkle:version>
            <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{minimum_system_version}</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure
                url="{url}"
                length="{l}"
                type="application/octet-stream"
                sparkle:edSignature="{s}"/>
        </item>"""

path = "appcast.xml"
with open(path) as f:
    content = f.read()
content = content.replace("    </channel>", item + "\n    </channel>")
with open(path, "w") as f:
    f.write(content)
PYEOF

git add "$APPCAST"
git commit -m "[build] Publish $TAG appcast"
git push origin main

echo ""
echo "==> Released $TAG"
echo "    https://github.com/palmier-io/palmier-pro/releases/tag/$TAG"
