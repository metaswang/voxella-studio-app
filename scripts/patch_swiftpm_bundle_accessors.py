#!/usr/bin/env python3
"""Validate generated bundle lookup and repair legacy paths/bundle-name mismatches."""
from pathlib import Path
import re
import stat
import sys


def find_accessors(build_dir: Path) -> list[Path]:
    paths = list(build_dir.glob('*.build/DerivedSources/resource_bundle_accessor.*'))
    if build_dir.parent.name == 'Products':
        paths.extend((build_dir.parent.parent / 'Intermediates.noindex').glob(
            f'*.build/{build_dir.name}/*.build/DerivedSources/resource_bundle_accessor.*'
        ))
    return sorted(path for path in set(paths) if path.suffix in ('.swift', '.m'))


def patch_accessor(path: Path, bundle_names: set[str]) -> bool:
    source = path.read_text()
    legacy = re.compile(r'Bundle\.main\.bundleURL\.appendingPathComponent\("([^\"]+\.bundle)"\)\.path')
    patched = legacy.sub(
        r'Bundle.main.bundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent("\1").path',
        source,
    )
    already_patched = re.search(
        r'Bundle\.main\.bundleURL\.appendingPathComponent\("Contents/Resources"\)'
        r'\.appendingPathComponent\("[^\"]+\.bundle"\)\.path', patched,
    )
    name = re.search(r'((?:let|NSString\s*\*)\s*bundleName\s*=\s*@?")([^\"]+)(")', patched)
    if name:
        expected = name.group(2)
        if expected not in bundle_names:
            matches = [value for value in bundle_names if re.sub(r'\W', '_', value) == expected]
            if len(matches) != 1:
                raise ValueError(f'Cannot resolve generated bundle name {expected} against built resources')
            patched = patched[:name.start(2)] + matches[0] + patched[name.end(2):]
        compatible = any(value in patched for value in (
            'Bundle.main.resourceURL', '[NSBundle mainBundle] resourceURL', 'NSBundle.mainBundle.resourceURL',
        ))
    else:
        compatible = bool(already_patched)
    if not compatible:
        raise ValueError(f'Unrecognized SwiftPM resource accessor: {path}')
    if patched == source:
        return False
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    path.write_text(patched)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: patch_swiftpm_bundle_accessors.py <swift-bin-directory>', file=sys.stderr)
        return 2
    build_dir = Path(sys.argv[1])
    accessors = find_accessors(build_dir)
    if not accessors:
        print(f'!! no SwiftPM resource accessors found under {build_dir}', file=sys.stderr)
        return 1
    names = {bundle.stem for bundle in build_dir.glob('*.bundle') if bundle.is_dir()}
    try:
        changed = sum(patch_accessor(path, names) for path in accessors)
    except (OSError, ValueError) as error:
        print(f'!! {error}', file=sys.stderr)
        return 1
    print(f'==> Verified {len(accessors)} SwiftPM resource accessors; repaired {changed}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
