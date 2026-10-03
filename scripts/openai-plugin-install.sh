#!/bin/bash
# This script is shipped at the extracted marketplace root as install.sh.
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME=voxstudio
PLUGIN_CLI=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli) [[ $# -ge 2 ]] || { printf 'Missing CLI path\n' >&2; exit 2; }; PLUGIN_CLI="$2"; shift 2 ;;
    --plugin) [[ $# -ge 2 ]] || { printf 'Missing plugin name\n' >&2; exit 2; }; PLUGIN_NAME="$2"; shift 2 ;;
    *) printf 'Usage: bash install.sh [--cli /path/to/codex] [--plugin voxstudio|voxstudio-knowledge]\n' >&2; exit 2 ;;
  esac
done
case "$PLUGIN_NAME" in voxstudio|voxstudio-knowledge) ;; *) printf 'Unknown plugin\n' >&2; exit 2 ;; esac
if [[ -n "$PLUGIN_CLI" ]]; then
  :
elif [[ -x /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex ]]; then
  PLUGIN_CLI=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
elif command -v codex >/dev/null 2>&1; then
  PLUGIN_CLI="$(command -v codex)"
else
  printf 'Install the ChatGPT desktop app or a Codex CLI with plugin support, then try again.\n' >&2
  exit 1
fi
if [[ ! -f "$PACKAGE_ROOT/.agents/plugins/marketplace.json" ]]; then
  printf 'Run the install.sh inside the fully extracted VoxStudio-OpenAI-Plugin folder.\n' >&2
  exit 1
fi
printf 'Installing %s@voxstudio-local from %s\n' "$PLUGIN_NAME" "$PACKAGE_ROOT"
"$PLUGIN_CLI" plugin marketplace add "$PACKAGE_ROOT" --json
"$PLUGIN_CLI" plugin add "$PLUGIN_NAME@voxstudio-local" --json
printf '\nInstallation finished. Keep this folder in place.\nEnable %s under VoxStudio Local in your desktop client, restart the client if needed, and open a new chat.\nKeep VoxStudio running with Settings > MCP enabled.\n' "$PLUGIN_NAME"
