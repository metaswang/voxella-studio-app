#!/usr/bin/env python3
"""Convert legacy `.vxst` project packages to the current VoxStudio layout; dry-run by default.

Legacy packages carry `format.vxst` ("voxstudio.project" + version) and store the same JSON
documents under different names. The current app reads `project.json`, `media.json` and
`generation-log.json` (see `Project` in Sources/VoxstudioPro/Utilities/Constants.swift).
Every package is copied to a backup directory before it is changed.

`--import-to-sandbox` additionally copies packages that live outside the Mac App Store
(TestFlight/MAS) container into `<container>/Data/Documents/VoxStudio` and repoints the project
registry at the copies. The sandboxed app has no access to other folders, so it reports such
projects as "isn't in the correct format" even though their files are valid.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import urllib.parse
import sys
import uuid

MARKER = 'format.vxst'
MARKER_KIND = 'voxstudio.project'
SUPPORTED_VERSIONS = {'1'}
# Legacy file -> current file. Contents are already the same JSON schema.
RENAMES = (
    ('timeline.vxst', 'project.json', True),
    ('library.vxst', 'media.json', False),
    ('generations.vxst', 'generation-log.json', False),
)
PROJECT_EXTENSIONS = ('.voxella', '.palmier')
MAS_BUNDLE_ID = 'com.voxella.studio'
CURRENT_FILE = 'project.json'


def default_root() -> Path:
    return Path.home() / 'Documents' / 'Voxella Studio'


def default_backup_root() -> Path:
    return Path.home() / 'Library' / 'Application Support' / 'VoxStudio' / 'Backups'


def sandbox_documents(bundle_id=MAS_BUNDLE_ID) -> Path:
    return Path.home() / 'Library' / 'Containers' / bundle_id / 'Data' / 'Documents' / 'VoxStudio'


def file_url(package: Path) -> str:
    return package.resolve().as_uri() + '/'


def path_from_url(url: str) -> Path:
    return Path(urllib.parse.unquote(urllib.parse.urlparse(url).path))


def import_to_sandbox(packages, documents: Path):
    """Copy current-layout packages into the sandbox container and repoint the registry."""
    registry_path = documents / 'project-registry.json'
    try:
        registry = json.loads(registry_path.read_text(encoding='utf-8')) if registry_path.is_file() else []
    except ValueError as error:
        return [{'package': str(documents), 'status': 'error', 'detail': f'unreadable registry: {error}'}]
    documents.mkdir(parents=True, exist_ok=True)
    results, now = [], datetime.datetime.now().timestamp() - 978307200  # Foundation reference date
    for package in packages:
        resolved = package.resolve()
        if documents.resolve() in resolved.parents:
            continue
        if not (package / CURRENT_FILE).is_file():
            results.append({'package': str(package), 'status': 'error', 'detail': f'no {CURRENT_FILE}; not importable'})
            continue
        target = documents / package.name
        if target.exists():
            results.append({'package': str(package), 'status': 'error', 'detail': f'{target} already exists; refusing to overwrite'})
            continue
        shutil.copytree(package, target, symlinks=True)
        old = next((entry for entry in registry if path_from_url(entry['url']).resolve() == resolved), None)
        if old:
            old['url'] = file_url(target)
        else:
            registry.append({'id': str(uuid.uuid4()).upper(), 'url': file_url(target),
                             'createdDate': now, 'lastOpenedDate': now})
        results.append({'package': str(package), 'status': 'imported', 'destination': str(target)})
    if any(item['status'] == 'imported' for item in results):
        temporary = registry_path.with_name('.project-registry.json.migrating')
        temporary.write_text(json.dumps(registry), encoding='utf-8')
        os.replace(temporary, registry_path)
    return results


def find_packages(roots):
    for root in roots:
        if root.suffix in PROJECT_EXTENSIONS and root.is_dir():
            yield root
            continue
        if root.is_dir():
            for child in sorted(root.iterdir()):
                if child.suffix in PROJECT_EXTENSIONS and child.is_dir():
                    yield child


def legacy_version(package: Path):
    marker = package / MARKER
    if not marker.is_file():
        return None
    lines = marker.read_text(encoding='utf-8').split()
    if len(lines) != 2 or lines[0] != MARKER_KIND:
        raise ValueError(f'unrecognized {MARKER}: {lines!r}')
    return lines[1]


def plan(package: Path):
    """Return the list of (source, destination) renames, or raise if the package cannot convert."""
    version = legacy_version(package)
    if version is None:
        return None
    if version not in SUPPORTED_VERSIONS:
        raise ValueError(f'unsupported {MARKER} version {version}')
    moves = []
    for legacy, current, required in RENAMES:
        source, destination = package / legacy, package / current
        if not source.exists():
            if required:
                raise ValueError(f'missing {legacy}')
            continue
        if destination.exists():
            raise ValueError(f'{current} already exists; refusing to overwrite')
        # Fail before touching anything if a document is not valid JSON.
        json.loads(source.read_text(encoding='utf-8'))
        moves.append((source, destination))
    return moves


def write_atomically(source: Path, destination: Path):
    temporary = destination.with_name(f'.{destination.name}.migrating')
    shutil.copy2(source, temporary)
    with open(temporary, 'rb') as handle:
        os.fsync(handle.fileno())
    os.replace(temporary, destination)


def convert(package: Path, moves, backup_root: Path):
    backup = backup_root / package.name
    shutil.copytree(package, backup, symlinks=True)
    for source, destination in moves:
        write_atomically(source, destination)
    for source, _ in moves:
        source.unlink()
    (package / MARKER).unlink()
    return backup


def migrate(roots, apply=False, backup_root=None, stamp=None):
    stamp = stamp or datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup_root = (backup_root or default_backup_root()) / f'vxst-migration-{stamp}'
    results = []
    for package in find_packages(roots):
        try:
            moves = plan(package)
        except (OSError, ValueError) as error:
            results.append({'package': str(package), 'status': 'error', 'detail': str(error)})
            continue
        if moves is None:
            continue
        renames = [f'{source.name} -> {destination.name}' for source, destination in moves]
        if not apply:
            results.append({'package': str(package), 'status': 'pending', 'renames': renames})
            continue
        try:
            backup = convert(package, moves, backup_root)
        except OSError as error:
            results.append({'package': str(package), 'status': 'error', 'detail': str(error)})
            continue
        results.append({'package': str(package), 'status': 'converted', 'renames': renames, 'backup': str(backup)})
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('paths', nargs='*', type=Path, help='project packages or folders (default: ~/Documents/Voxella Studio)')
    parser.add_argument('--apply', action='store_true', help='write changes (default is a dry run)')
    parser.add_argument('--backup-root', type=Path, help='backup parent directory')
    parser.add_argument('--import-to-sandbox', action='store_true',
                        help='with --apply, copy packages into the MAS app container and repoint its registry; quit the app first')
    parser.add_argument('--bundle-id', default=MAS_BUNDLE_ID, help=f'container bundle id (default {MAS_BUNDLE_ID})')
    args = parser.parse_args(argv)
    roots = args.paths or [default_root()]
    results = migrate(roots, apply=args.apply, backup_root=args.backup_root)
    if args.import_to_sandbox:
        if args.apply:
            results += import_to_sandbox(list(find_packages(roots)), sandbox_documents(args.bundle_id))
        else:
            results += [{'package': str(package), 'status': 'pending-import'} for package in find_packages(roots)
                        if sandbox_documents(args.bundle_id).resolve() not in package.resolve().parents]
    print(json.dumps(results, ensure_ascii=False, indent=2))
    if not args.apply and any(item['status'] == 'pending' for item in results):
        print('Dry run only. Re-run with --apply to convert.', file=sys.stderr)
    return 1 if any(item['status'] == 'error' for item in results) else 0


if __name__ == '__main__':
    sys.exit(main())
