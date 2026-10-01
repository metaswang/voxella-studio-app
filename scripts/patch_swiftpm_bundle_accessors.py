#!/usr/bin/env python3
"""Point generated SwiftPM resource accessors into a signed macOS app bundle."""

from __future__ import annotations

import re
import stat
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_swiftpm_bundle_accessors.py <swift-bin-directory>", file=sys.stderr)
        return 2

    build_dir = Path(sys.argv[1])
    accessors = sorted(build_dir.glob("*.build/DerivedSources/resource_bundle_accessor.swift"))
    if not accessors:
        print(f"!! no SwiftPM resource accessors found under {build_dir}", file=sys.stderr)
        return 1

    pattern = re.compile(
        r'Bundle\.main\.bundleURL\.appendingPathComponent\("([^\"]+\.bundle)"\)\.path'
    )
    already_patched = re.compile(
        r'Bundle\.main\.bundleURL\.appendingPathComponent\("Contents/Resources"\)'
        r'\.appendingPathComponent\("([^\"]+\.bundle)"\)\.path'
    )
    expected = {"VoxstudioPro_VoxstudioPro.bundle", "YouTubeKit_YouTubeKit.bundle"}
    patched_names: set[str] = set()
    accessor_count = 0

    for accessor in accessors:
        source = accessor.read_text(encoding="utf-8")
        patched_names.update(already_patched.findall(source))

        def resource_path(match: re.Match[str]) -> str:
            patched_names.add(match.group(1))
            return (
                'Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")'
                f'.appendingPathComponent("{match.group(1)}").path'
            )

        patched, count = pattern.subn(resource_path, source)
        if count:
            mode = stat.S_IMODE(accessor.stat().st_mode)
            accessor.chmod(mode | stat.S_IWUSR)
            accessor.write_text(patched, encoding="utf-8")
            accessor_count += 1

    missing = expected - patched_names
    if missing:
        print(
            "!! SwiftPM resource accessors did not contain expected bundles: "
            + ", ".join(sorted(missing)),
            file=sys.stderr,
        )
        return 1

    print(
        f"==> Patched {accessor_count} SwiftPM resource accessors "
        "to use Contents/Resources"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
