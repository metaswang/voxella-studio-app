#!/usr/bin/env python3
"""Locate resources in flat SwiftPM bundles and macOS structured bundles."""
from pathlib import Path
import sys


def bundle_resource_directory(bundle: Path) -> Path:
    structured = bundle / 'Contents/Resources'
    return structured if structured.is_dir() else bundle


def resource_path(resources: Path, relative: str) -> Path:
    path = Path(relative)
    if path.parts and path.parts[0].endswith('.bundle'):
        return bundle_resource_directory(resources / path.parts[0]).joinpath(*path.parts[1:])
    return resources / path


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: bundle_resources.py <resource-bundle>')
    print(bundle_resource_directory(Path(sys.argv[1])))
