#!/usr/bin/env python3
"""Generate host compatibility manifests from the portable plugin sources."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
plugin = root / 'Plugins/voxstudio'
manifest = json.loads((plugin / 'plugin.json').read_text())
config = json.loads((plugin / 'mcp.json').read_text())
legacy = {k: v for k, v in manifest.items() if k != '$schema'}
legacy.update(skills='./skills/', mcpServers='./.mcp.json', interface=manifest['extensions']['com.openai']['interface'])
(plugin / '.codex-plugin').mkdir(exist_ok=True)
(plugin / '.codex-plugin/plugin.json').write_text(json.dumps(legacy, ensure_ascii=False, indent=2) + '\n')
legacy_config = {'mcpServers': {k: {**v, 'type': 'http'} for k, v in config['mcpServers'].items()}}
(plugin / '.mcp.json').write_text(json.dumps(legacy_config, indent=2) + '\n')
marketplace = root / '.agents/plugins'
marketplace.mkdir(parents=True, exist_ok=True)
(marketplace / 'marketplace.json').write_text(json.dumps({'name':'voxstudio-local','interface':{'displayName':'VoxStudio Local'},'plugins':[{'name':manifest['name'],'source':{'source':'local','path':'./Plugins/voxstudio'},'policy':{'installation':'AVAILABLE','authentication':'ON_INSTALL'},'category':'Productivity'}]}, indent=2) + '\n')
print('Generated voxstudio@voxstudio-local version', manifest['version'])
