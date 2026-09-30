#!/usr/bin/env python3
"""Rename legacy VoxStudio MCP connections and exported skills; dry-run by default."""
import argparse
import datetime
import json
from pathlib import Path
import re
import shutil

ALIASES = ('palmier-pro', 'voxella-studio')


def migrate(home: Path, apply: bool = False):
    changes = []
    stamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')

    def save(path, content):
        if apply:
            shutil.copy2(path, path.with_name(path.name + '.voxstudio-backup-' + stamp))
            path.write_text(content)

    def rename_servers(value, location=''):
        changed = False
        if isinstance(value, dict):
            servers = value.get('mcpServers')
            if isinstance(servers, dict):
                for old in ALIASES:
                    if old not in servers:
                        continue
                    if 'voxstudio' in servers and servers['voxstudio'] != servers[old]:
                        raise ValueError(f'Conflicting voxstudio connection at {location}; left unchanged')
                    servers['voxstudio'] = servers.pop(old)
                    changed = True
            for key, child in value.items():
                if key != 'mcpServers':
                    changed = rename_servers(child, location + '/' + key) or changed
        elif isinstance(value, list):
            for child in value:
                changed = rename_servers(child, location) or changed
        return changed

    configs = [home / '.cursor/mcp.json', home / '.claude.json',
               home / 'Library/Application Support/Claude/claude_desktop_config.json']
    for path in configs:
        if not path.exists():
            continue
        content = json.loads(path.read_text())
        if rename_servers(content, str(path)):
            save(path, json.dumps(content, ensure_ascii=False, indent=2) + '\n')
            changes.append(str(path))

    path = home / '.codex/config.toml'
    if path.exists():
        text = path.read_text()
        pattern = r'(?m)^(\[mcp_servers\.)(?:"(?:palmier-pro|voxella-studio)"|palmier-pro|voxella-studio)(?=[.\]])'
        if re.search(pattern, text):
            if re.search(r'(?m)^\[mcp_servers\.(?:"voxstudio"|voxstudio)(?=[.\]])', text):
                raise ValueError('Conflicting Codex voxstudio connection; left unchanged')
            save(path, re.sub(pattern, r'\1voxstudio', text))
            changes.append(str(path))

    for client in ('.cursor', '.codex', '.claude'):
        root = home / client / 'skills'
        if not root.exists():
            continue
        for source in sorted(root.iterdir()):
            prefix = next((p for p in ('palmier-', 'voxella-studio-') if source.name.startswith(p)), None)
            if prefix is None or source.is_symlink() or not (source / 'SKILL.md').is_file():
                continue
            destination = root / ('voxstudio-' + source.name[len(prefix):])
            if destination.exists():
                raise ValueError(f'Skill destination already exists: {destination}; left unchanged')
            if apply:
                source.rename(destination)
            changes.append(f'{source} -> {destination}')
    return changes


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--home', type=Path, default=Path.home())
    args = parser.parse_args()
    for change in migrate(args.home, args.apply):
        print(('Migrated: ' if args.apply else 'Would migrate: ') + change)
