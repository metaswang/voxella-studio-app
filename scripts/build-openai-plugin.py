#!/usr/bin/env python3
"""Generate both independently installable host compatibility manifests."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
entries = []
for name in ("voxstudio", "voxstudio-knowledge"):
    plugin = root / "Plugins" / name
    manifest = json.loads((plugin / "plugin.json").read_text())
    config = json.loads((plugin / "mcp.json").read_text())
    legacy = {k: v for k, v in manifest.items() if k != "$schema"}
    legacy.update(skills="./skills/", mcpServers="./.mcp.json", interface=manifest["extensions"]["com.openai"]["interface"])
    (plugin / ".codex-plugin").mkdir(exist_ok=True)
    (plugin / ".codex-plugin/plugin.json").write_text(json.dumps(legacy, ensure_ascii=False, indent=2) + "\n")
    (plugin / ".mcp.json").write_text(json.dumps({"mcpServers": {k: {**v, "type": "http"} for k, v in config["mcpServers"].items()}}, indent=2) + "\n")
    entries.append({"name": name, "source": {"source": "local", "path": "./Plugins/" + name}, "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}, "category": "Productivity"})
marketplace = root / ".agents/plugins"
marketplace.mkdir(parents=True, exist_ok=True)
(marketplace / "marketplace.json").write_text(json.dumps({"name": "voxstudio-local", "interface": {"displayName": "VoxStudio Local"}, "plugins": entries}, indent=2) + "\n")
print("Generated separately installable VoxStudio and VoxStudio Knowledge manifests")
