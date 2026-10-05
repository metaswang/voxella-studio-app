#!/usr/bin/env python3
"""Install the single VoxStudio connection with verified, reversible migration."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request
MAIN='voxstudio@voxstudio-local'
OLD='voxstudio-knowledge@voxstudio-local'

def plugin_pattern(identity):
    return r'(?m)^\[plugins\."'+re.escape(identity)+r'"(?:\.[^\n\]]+)?\]\s*\n.*?(?=^\[|\Z)'

def section(text, identity):
    return ''.join(match.group() for match in re.finditer(plugin_pattern(identity),text,re.S))

def restore_sections(config, original, enabled):
    text=config.read_text() if config.exists() else ''
    for identity in (MAIN,OLD):
        text=re.sub(plugin_pattern(identity),'',text,flags=re.S)
        prior=section(original,identity)
        if prior: text+='\n'+prior
        elif identity==MAIN and enabled is not None:text+=f'\n[plugins."{MAIN}"]\nenabled = {str(enabled).lower()}\n'
    config.parent.mkdir(parents=True,exist_ok=True)
    temp=config.with_suffix('.voxstudio.tmp');temp.write_text(text);temp.replace(config)

def probe():
    endpoint='http://127.0.0.1:19789/app/mcp'
    def call(method,params=None):
        body=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or {}}).encode()
        req=urllib.request.Request(endpoint,body,{'Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-06-18'})
        with urllib.request.urlopen(req,timeout=10) as response:
            text=response.read().decode()
            sse=response.headers.get_content_type()=='text/event-stream'
        if sse or text.startswith('event:') or text.startswith('data:'):
            rows=[json.loads(line[5:].strip()) for line in text.splitlines() if line.startswith('data:') and line[5:].lstrip().startswith('{')]
            result=next(row for row in rows if row.get('id')==1)
        else: result=json.loads(text)
        if 'error' in result:raise RuntimeError(result['error']['message'])
        return result['result']
    call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'voxstudio-installer','version':'0.2.0'}})
    names={row['name'] for row in call('tools/list')['tools']}
    assert {'voxstudio.workspace','app_knowledge','knowledge.complete_turn','search','fetch'}<=names,'Unified App is not ready'
    ui=call('resources/read',{'uri':'ui://voxstudio/workspace/v1'})['contents']
    assert any(row.get('mimeType')=='text/html;profile=mcp-app' and 'voxstudio-session-companion-v1' in row.get('text','') for row in ui),'Session UI is missing from the running App'

def migrate(root,cli,codex_home,verify=probe):
    def run(*args):
        result=subprocess.run([cli,'plugin',*args,'--json'],capture_output=True,text=True,check=True)
        return json.loads(result.stdout)
    for line in (root/'FILES.sha256').read_text().splitlines():
        digest,name=line.split('  ',1)
        assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,f'Package checksum mismatch: {name}'
    manifest=json.loads((root/'plugins/voxstudio/plugin.json').read_text())
    verify() # Before changing any installation.
    installed={row['pluginId']:row for row in run('list').get('installed',[]) if row['pluginId'] in (MAIN,OLD)}
    config=codex_home/'config.toml';original=config.read_text() if config.exists() else ''
    # tools/list can omit an installed legacy plugin after its mutable source
    # marketplace drops that entry. Its immutable cache and preference are evidence.
    for identity in (MAIN,OLD):
        # A completed unified migration deliberately keeps dormant rollback
        # preferences and caches. Do not resurrect Knowledge from those alone.
        if identity==OLD and installed.get(MAIN,{}).get('version')==manifest['version']:continue
        name=identity.split('@')[0];preferences=section(original,identity)
        cached=codex_home/'plugins/cache/voxstudio-local'/name
        versions=sorted(cached.iterdir(),key=lambda p:tuple(int(x) for x in p.name.split('.')),reverse=True) if cached.is_dir() else []
        if identity not in installed and preferences and versions:
            package=versions[0];cached_manifest=json.loads((package/'plugin.json').read_text())
            enabled=re.search(r'(?m)^enabled\s*=\s*(true|false)',preferences)
            installed[identity]={'pluginId':identity,'name':name,'version':cached_manifest['version'],'enabled':not enabled or enabled[1]=='true','source':{'source':'local','path':str(package)},'authPolicy':'ON_INSTALL'}
    def register(folder):
        current=next((row for row in run('marketplace','list').get('marketplaces',[]) if row['name']=='voxstudio-local'),None)
        if current and Path(current['root']).resolve()!=folder.resolve():run('marketplace','remove','voxstudio-local')
        run('marketplace','add',str(folder))
    enabled=installed.get(MAIN,installed.get(OLD,{})).get('enabled')
    backup=root/'.migration'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');backup.mkdir(parents=True)
    (backup/'state.json').write_text(json.dumps(installed,indent=2)+'\n');(backup/'config.toml').write_text(original)
    entries=[]
    for identity,row in installed.items():
        name=row['name'];cache=codex_home/'plugins/cache/voxstudio-local'/name/row['version']
        # Copy the immutable installed version, never the mutable marketplace source.
        if not cache.is_dir():raise RuntimeError(f'Cannot safely back up {identity} {row["version"]}; installed cache is missing')
        shutil.copytree(cache,backup/'plugins'/name)
        entries.append({'name':name,'source':{'source':'local','path':'./plugins/'+name},'policy':{'installation':'AVAILABLE','authentication':row.get('authPolicy','ON_INSTALL')}})
    market=backup/'.agents/plugins';market.mkdir(parents=True)
    (market/'marketplace.json').write_text(json.dumps({'name':'voxstudio-local','plugins':entries}))
    changed=False
    try:
        changed=True
        register(root);run('add',MAIN)
        restore_sections(config,original,enabled)
        current={row['pluginId']:row for row in run('list').get('installed',[])}
        assert current[MAIN]['version']==manifest['version'],'Installed version does not match package'
        if enabled is not None:assert current[MAIN]['enabled']==enabled,'Enable preference changed'
        verify()
        if OLD in installed:run('remove',OLD)
        # Keep original plugin policy blocks as dormant preferences for rollback.
        restore_sections(config,original,enabled)
        return backup
    except Exception:
        if changed:
            try:
                if entries:
                    register(backup)
                    for identity in installed:run('add',identity)
                    if MAIN not in installed:run('remove',MAIN)
                else:run('remove',MAIN)
                restore_sections(config,original,enabled)
            except Exception as rollback:
                raise RuntimeError(f'Migration failed and automatic rollback failed: {rollback}. Recovery files: {backup}')
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--cli');parser.add_argument('--plugin',choices=['voxstudio'],default='voxstudio')
    args=parser.parse_args();root=Path(__file__).resolve().parent
    bundled='/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'
    cli=args.cli or (bundled if Path(bundled).is_file() else shutil.which('codex'))
    if not cli:parser.error('Install a desktop client with plugin support first')
    home=Path(os.environ.get('CODEX_HOME',str(Path.home()/'.codex')))
    backup=migrate(root,cli,home)
    print(f'Installed VoxStudio 0.2.0. Recovery snapshot: {backup}\nKeep this extracted folder. Open a new chat; your existing enable preference was preserved.')
if __name__=='__main__':
    try:main()
    except Exception as error:print(f'VoxStudio installation failed: {error}',file=sys.stderr);sys.exit(1)
