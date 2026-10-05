#!/usr/bin/env python3
"""Use the App's canonical icon in both connectors and embedded MCP panels."""
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def sync(root=ROOT):
    icon=(root/'Sources/VoxstudioPro/Resources/AppIcon.png').read_bytes()
    for name in ['mcpb/icon.png','Plugins/voxstudio/assets/icon.png']:
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(icon)
    data=base64.b64encode(icon).decode('ascii')
    (root/'mcp-ui/shared/logo.ts').write_text('// Generated from Resources/AppIcon.png by scripts/sync-mcp-branding.py.\nexport const voxStudioLogo = "data:image/png;base64,'+data+'";\n')

if __name__=='__main__':
    sync()
    print('MCP connectors and panels use the VoxStudio App icon')
