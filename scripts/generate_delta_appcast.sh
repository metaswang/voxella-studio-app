#!/bin/bash
set -euo pipefail

# Usage: scripts/generate_delta_appcast.sh --archives-dir DIR --output FILE --private-key FILE [--download-url-prefix URL] [--max-archives N]
#
# Generates a Sparkle 2.x appcast with delta updates from archived DMGs.
# Requires Sparkle's generate_appcast tool.

ARCHIVES_DIR=""
OUTPUT=""
PRIVATE_KEY=""
DOWNLOAD_URL_PREFIX=""
MAX_ARCHIVES=5

usage() {
  echo "usage: $0 --archives-dir DIR --output FILE --private-key FILE [--download-url-prefix URL] [--max-archives N]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --archives-dir)
      ARCHIVES_DIR="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY="$2"
      shift 2
      ;;
    --download-url-prefix)
      DOWNLOAD_URL_PREFIX="$2"
      shift 2
      ;;
    --max-archives)
      MAX_ARCHIVES="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      ;;
  esac
done

if [ -z "$ARCHIVES_DIR" ] || [ -z "$OUTPUT" ] || [ -z "$PRIVATE_KEY" ]; then
  usage
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_TOOLS="$ROOT/.build/sparkle-tools"
GENERATE_APPCAST="$SPARKLE_TOOLS/bin/generate_appcast"

ensure_sparkle_tools() {
  if [ -x "$GENERATE_APPCAST" ]; then
    return
  fi
  mkdir -p "$SPARKLE_TOOLS"
  local archive="$ROOT/.build/Sparkle-2.9.2.tar.xz"
  echo "==> Downloading Sparkle 2.9.2 tools" >&2
  curl -L --fail --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz" \
    -o "$archive"
  tar -xJf "$archive" -C "$SPARKLE_TOOLS"
  if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "error: generate_appcast tool not found after extraction" >&2
    exit 1
  fi
}

ensure_sparkle_tools

if [ ! -d "$ARCHIVES_DIR" ]; then
  echo "error: archives directory does not exist: $ARCHIVES_DIR" >&2
  exit 1
fi

if [ ! -f "$PRIVATE_KEY" ]; then
  echo "error: private key not found: $PRIVATE_KEY" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "==> Collecting up to $MAX_ARCHIVES recent archives from $ARCHIVES_DIR" >&2
ARCHIVES=($(find "$ARCHIVES_DIR" -name "*.dmg" -type f -print0 | xargs -0 ls -t | head -n "$MAX_ARCHIVES"))

if [ "${#ARCHIVES[@]}" -eq 0 ]; then
  echo "error: no DMG files found in $ARCHIVES_DIR" >&2
  exit 1
fi

for dmg in "${ARCHIVES[@]}"; do
  cp "$dmg" "$TEMP_DIR/"
done

DMG_COUNT="${#ARCHIVES[@]}"
echo "==> Generating appcast with $DMG_COUNT archives (Sparkle will compute deltas)" >&2

GENERATE_ARGS=("$TEMP_DIR" --ed-key-file "$PRIVATE_KEY" -o "$OUTPUT")
if [ -n "$DOWNLOAD_URL_PREFIX" ]; then
  GENERATE_ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi

"$GENERATE_APPCAST" "${GENERATE_ARGS[@]}"

echo "==> Appcast written to $OUTPUT" >&2
