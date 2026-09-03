#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_ROOT/../.." && pwd)"

DMG="$REPO_ROOT/.build/VoxStudio.dmg"
REPO_ID="$(printenv HF_REPO_ID || true)"
REVISION="$(printenv HF_REVISION || true)"
REMOTE_PATH="$(printenv HF_REMOTE_PATH || true)"
REPO_TYPE="$(printenv HF_REPO_TYPE || true)"
COMMIT_MESSAGE="$(printenv HF_COMMIT_MESSAGE || true)"
HF_PYTHON_VERSION="$(printenv HF_PYTHON_VERSION || true)"

if [[ -z "$REPO_ID" ]]; then REPO_ID='hfadam/VoxStudio.app'; fi
if [[ -z "$REVISION" ]]; then REVISION='main'; fi
if [[ -z "$REMOTE_PATH" ]]; then REMOTE_PATH='VoxStudio.dmg'; fi
if [[ -z "$REPO_TYPE" ]]; then REPO_TYPE='model'; fi
if [[ -z "$COMMIT_MESSAGE" ]]; then COMMIT_MESSAGE='Upload verified VoxStudio DMG'; fi
if [[ -z "$HF_PYTHON_VERSION" ]]; then HF_PYTHON_VERSION='3.12.12'; fi

usage() {
  cat <<'USAGE'
Usage:
  upload_dmg_to_huggingface.sh [options]

Options:
  --dmg PATH             Local DMG path. Default: .build/VoxStudio.dmg
  --repo-id ID           Hugging Face repository. Default: hfadam/VoxStudio.app
  --repo-type TYPE       Repository type. Default: model
  --revision REVISION    Target revision. Default: main
  --remote-path PATH     Path in the repository. Default: VoxStudio.dmg
  --commit-message TEXT  Commit message
  -h, --help             Show this help

Environment overrides:
  HF_REPO_ID, HF_REPO_TYPE, HF_REVISION, HF_REMOTE_PATH,
  HF_COMMIT_MESSAGE, HF_PYTHON_VERSION

The script requires an existing Hugging Face CLI login. It does not accept
tokens as arguments and never prints token values.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ $# -ge 2 ]] || { echo '--dmg requires a path' >&2; exit 2; }
      DMG="$2"
      shift 2
      ;;
    --repo-id)
      [[ $# -ge 2 ]] || { echo '--repo-id requires an ID' >&2; exit 2; }
      REPO_ID="$2"
      shift 2
      ;;
    --repo-type)
      [[ $# -ge 2 ]] || { echo '--repo-type requires model, dataset, or space' >&2; exit 2; }
      REPO_TYPE="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || { echo '--revision requires a revision' >&2; exit 2; }
      REVISION="$2"
      shift 2
      ;;
    --remote-path)
      [[ $# -ge 2 ]] || { echo '--remote-path requires a path' >&2; exit 2; }
      REMOTE_PATH="$2"
      shift 2
      ;;
    --commit-message)
      [[ $# -ge 2 ]] || { echo '--commit-message requires text' >&2; exit 2; }
      COMMIT_MESSAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$REPO_TYPE" in
  model|dataset|space) ;;
  *)
    echo '--repo-type must be model, dataset, or space' >&2
    exit 2
    ;;
esac

if [[ "$DMG" != /* ]]; then
  DMG="$REPO_ROOT/$DMG"
fi
if [[ ! -f "$DMG" ]]; then
  echo "DMG not found: $DMG" >&2
  exit 1
fi
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"

if [[ "$REPO_ID" != */* ]]; then
  echo "Repository must include an owner and name: $REPO_ID" >&2
  exit 2
fi
if [[ "$REMOTE_PATH" == /* || ! "$REMOTE_PATH" =~ ^[A-Za-z0-9._/-]+$ || "$REMOTE_PATH" == *..* ]]; then
  echo "Remote path contains unsupported or unsafe characters: $REMOTE_PATH" >&2
  exit 2
fi

HF_COMMAND=''
HF_USE_PYENV='0'
if command -v hf >/dev/null 2>&1 && hf --help >/dev/null 2>&1; then
  HF_COMMAND='hf'
elif command -v pyenv >/dev/null 2>&1 && PYENV_VERSION="$HF_PYTHON_VERSION" pyenv which huggingface-cli >/dev/null 2>&1; then
  HF_COMMAND='huggingface-cli'
  HF_USE_PYENV='1'
elif command -v huggingface-cli >/dev/null 2>&1 && huggingface-cli --help >/dev/null 2>&1; then
  HF_COMMAND='huggingface-cli'
else
  echo 'No working Hugging Face CLI found. Install hf or configure the project Python environment.' >&2
  exit 1
fi

run_hf() {
  if [[ "$HF_USE_PYENV" == '1' ]]; then
    PYENV_VERSION="$HF_PYTHON_VERSION" "$HF_COMMAND" "$@"
  else
    "$HF_COMMAND" "$@"
  fi
}

WHOAMI_MODE=''
if run_hf auth whoami >/dev/null 2>&1; then
  WHOAMI_MODE='auth'
elif run_hf whoami >/dev/null 2>&1; then
  WHOAMI_MODE='legacy'
else
  echo 'Hugging Face CLI is not authenticated. Log in before uploading.' >&2
  exit 1
fi

if [[ "$WHOAMI_MODE" == 'auth' ]]; then
  ACCOUNT="$(run_hf auth whoami)"
else
  ACCOUNT="$(run_hf whoami)"
fi
echo "Hugging Face CLI account verified: $ACCOUNT"

if stat -f '%z' "$DMG" >/dev/null 2>&1; then
  LOCAL_SIZE="$(stat -f '%z' "$DMG")"
else
  LOCAL_SIZE="$(stat -c '%s' "$DMG")"
fi
LOCAL_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

echo "Uploading $DMG"
echo "Local bytes: $LOCAL_SIZE"
echo "Local SHA-256: $LOCAL_SHA"

run_hf upload "$REPO_ID" "$DMG" "$REMOTE_PATH" \
  --repo-type "$REPO_TYPE" \
  --revision "$REVISION" \
  --commit-message "$COMMIT_MESSAGE"

REMOTE_URL="https://huggingface.co/$REPO_ID/resolve/$REVISION/$REMOTE_PATH?download=true"
HEADERS="$(curl -fsSIL --max-time 60 "$REMOTE_URL")"
REMOTE_COMMIT="$(printf '%s\n' "$HEADERS" | awk 'BEGIN { IGNORECASE=1 } /^x-repo-commit:/ { sub(/\r$/, "", $2); print $2; exit }')"
REMOTE_SHA="$(printf '%s\n' "$HEADERS" | awk 'BEGIN { IGNORECASE=1 } /^x-linked-etag:/ { gsub(/[ "\r]/, "", $2); print $2; exit }')"
REMOTE_SIZE="$(printf '%s\n' "$HEADERS" | awk 'BEGIN { IGNORECASE=1 } /^content-length:/ { sub(/\r$/, "", $2); print $2; exit }')"

TREE_JSON=''
if [[ -z "$REMOTE_SHA" || -z "$REMOTE_SIZE" ]]; then
  case "$REPO_TYPE" in
    model) TREE_URL="https://huggingface.co/api/models/$REPO_ID/tree/$REVISION?recursive=true" ;;
    dataset) TREE_URL="https://huggingface.co/api/datasets/$REPO_ID/tree/$REVISION?recursive=true" ;;
    space) TREE_URL="https://huggingface.co/api/spaces/$REPO_ID/tree/$REVISION?recursive=true" ;;
  esac
  TREE_JSON="$(curl -fsSL --max-time 60 "$TREE_URL")"
fi

if [[ -z "$REMOTE_SHA" && -n "$TREE_JSON" ]]; then
  REMOTE_SHA="$(printf '%s' "$TREE_JSON" | python3 -c 'import json,sys; path=sys.argv[1]; data=json.load(sys.stdin); matches=[item for item in data if item.get("path")==path]; item=matches[0] if matches else {}; lfs=item.get("lfs") or {}; print(lfs.get("sha256") or lfs.get("oid") or "")' "$REMOTE_PATH")"
fi
if [[ -z "$REMOTE_SIZE" && -n "$TREE_JSON" ]]; then
  REMOTE_SIZE="$(printf '%s' "$TREE_JSON" | python3 -c 'import json,sys; path=sys.argv[1]; data=json.load(sys.stdin); matches=[item for item in data if item.get("path")==path]; print(matches[0].get("size") or "" if matches else "")' "$REMOTE_PATH")"
fi

if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
  echo "Remote size mismatch: local=$LOCAL_SIZE remote=$REMOTE_SIZE" >&2
  exit 1
fi
if [[ -z "$REMOTE_SHA" ]]; then
  echo 'Upload completed, but Hugging Face did not expose a verifiable SHA-256 for the remote file.' >&2
  exit 1
fi

NORMALIZED_REMOTE_SHA="$(printf '%s' "$REMOTE_SHA" | tr '[:upper:]' '[:lower:]')"
if [[ "$NORMALIZED_REMOTE_SHA" != "$LOCAL_SHA" ]]; then
  echo "Remote SHA-256 mismatch: local=$LOCAL_SHA remote=$REMOTE_SHA" >&2
  exit 1
fi

echo "Remote bytes: $REMOTE_SIZE"
echo "Remote SHA-256: $REMOTE_SHA"
echo "Remote commit: $REMOTE_COMMIT"
echo "Download URL: $REMOTE_URL"
