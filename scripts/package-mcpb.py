#!/usr/bin/env python3
"""Reproducible Claude Desktop extension; verify source/version/endpoint before packing."""
import argparse
import json
from pathlib import Path
import zipfile
ROOT = Path(__file__).resolve().parents[1]
FILES = ('manifest.json', 'icon.png', 'server/index.js', 'server/stdio.js', 'server/package.json')
def package(root=ROOT, output=None):
    source=root/'mcpb'
    manifest=json.loads((source/'manifest.json').read_text())
    server=json.loads((source/'server/package.json').read_text())
    assert manifest['name']=='voxstudio' and manifest['version']==server['version']=='0.3.1'
    assert manifest['server']['entry_point']=='server/stdio.js'
    assert manifest['server']['mcp_config']['args']==['${__dirname}/server/stdio.js']
    assert server['main']=='stdio.js'
    assert "require('./index.js').startStdio();" in (source/'server/stdio.js').read_text()
    assert (source/'icon.png').read_bytes() == (root/'Sources/VoxstudioPro/Resources/AppIcon.png').read_bytes(), 'Run scripts/sync-mcp-branding.py before packaging'
    assert "const URL_BASE = 'http://127.0.0.1:19789/app/mcp';" in (source/'server/index.js').read_text()
    output=output or root/'Sources/VoxstudioPro/Resources/MCPB/voxstudio.mcpb'
    output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name in FILES:
            entry=zipfile.ZipInfo(name,(2026,1,1,0,0,0));entry.create_system=3;entry.external_attr=0o100644<<16;entry.compress_type=zipfile.ZIP_DEFLATED
            archive.writestr(entry,(source/name).read_bytes(),compresslevel=9)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None and set(archive.namelist())==set(FILES)
        for name in FILES: assert archive.read(name)==(source/name).read_bytes()
    return output
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path)
    print(package(output=parser.parse_args().output))
