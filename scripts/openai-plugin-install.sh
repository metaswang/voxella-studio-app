#!/bin/bash
# This script is shipped at the extracted marketplace root as install.sh.
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# == 2 && "$1" == "--cli" ]]; then
  PLUGIN_CLI="$2"
elif [[ $# != 0 ]]; then
  printf 'Usage: bash install.sh [--cli /absolute/path/to/codex]\n' >&2
  exit 2
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
printf 'Installing voxstudio@voxstudio-local from %s\n' "$PACKAGE_ROOT"
"$PLUGIN_CLI" plugin marketplace add "$PACKAGE_ROOT" --json
"$PLUGIN_CLI" plugin add voxstudio@voxstudio-local --json
printf '\nInstallation finished. Keep this folder in place.\nEnable VoxStudio in your desktop client, restart the client if needed, and open a new chat.\nKeep VoxStudio running with Settings > MCP enabled.\n'
