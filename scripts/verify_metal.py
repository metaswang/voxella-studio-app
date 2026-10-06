#!/usr/bin/env python3
"""Verify packaged shader provenance and loadability on the current real Mac."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from build_metal import ROOT, LANGUAGE, MINIMUM, capture, sha
from bundle_resources import bundle_resource_directory, resource_path


def verify_resources(resources, minimum):
    manifest = json.loads((resources / "metal-build.json").read_text())
    if (manifest.get("schema"), manifest.get("minimum_macos"), manifest.get("language"),
            manifest.get("architecture")) != (1, minimum, LANGUAGE, "arm64"):
        raise ValueError("Packaged Metal policy does not match the app")
    expected = {p.stem + ".metallib" for p in (ROOT / "Metal").glob("*.metal")}
    expected.add("mlx-swift_Cmlx.bundle/default.metallib")
    entries = manifest["libraries"]
    # VoxstudioPro's SwiftPM bundle contains copies of the CI libraries as module
    # resources, while the app also keeps the canonical copies at its resource
    # root for BundledResource. Count the app load paths here; the nested module
    # copies are checked below for byte-for-byte consistency.
    actual = {p.name for p in resources.glob("*.metallib")}
    mlx_library = resource_path(resources, "mlx-swift_Cmlx.bundle/default.metallib")
    if mlx_library.is_file():
        actual.add("mlx-swift_Cmlx.bundle/default.metallib")
    if set((resources / "mlx-swift_Cmlx.bundle").rglob("*.metallib")) != {mlx_library}:
        raise ValueError("Missing, duplicate, or unexpected packaged MLX libraries")
    if len(entries) != len(expected) or {e["path"] for e in entries} != expected or actual != expected:
        raise ValueError("Missing, duplicate, or unexpected packaged Metal libraries")
    for entry in entries:
        path = resource_path(resources, entry["path"])
        if path.stat().st_size != entry["bytes"] or sha(path) != entry["sha256"]:
            raise ValueError(f"Packaged shader differs from build manifest: {entry['path']}")
        module_copy = bundle_resource_directory(resources / "VoxstudioPro_VoxstudioPro.bundle") / path.name
        if module_copy.exists() and sha(module_copy) != sha(path):
            raise ValueError(f"SwiftPM module shader copy differs from app resource: {path.name}")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path, help="Save JSON evidence outside the signed app")
    args = parser.parse_args()
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info["LSMinimumSystemVersion"] != MINIMUM:
        raise ValueError(f"Expected app deployment target {MINIMUM}")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if capture(["lipo", "-archs", str(binary)]) != "arm64":
        raise ValueError("Expected one arm64 app for Apple silicon")
    load_commands = capture(["otool", "-l", str(binary)])
    minimum = re.search(r"cmd LC_BUILD_VERSION\s[\s\S]*?\n\s+minos (\S+)", load_commands)
    if not minimum or minimum.group(1) != MINIMUM:
        raise ValueError("Executable Mach-O minimum does not match the Metal policy")
    resources = app / "Contents/Resources"
    manifest = verify_resources(resources, info["LSMinimumSystemVersion"])
    with tempfile.TemporaryDirectory(prefix="voxstudio-metal-verify-") as temp:
        probe = Path(temp) / "verify-metal"
        subprocess.run(["xcrun", "clang", "-arch", "arm64", f"-mmacosx-version-min={MINIMUM}",
                        "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal",
                        "-framework", "CoreImage", str(ROOT / "scripts/verify_metal.m"),
                        "-o", str(probe)], check=True)
        host = json.loads(subprocess.check_output([str(probe), str(resources)], text=True))
    report = {"app_version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
              "binary_sha256": sha(binary), "metal_manifest_sha256": sha(resources / "metal-build.json"),
              "shader_bytes": sum(e["bytes"] for e in manifest["libraries"]), "host": host}
    data = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(data)
    print(data, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output)
        raise SystemExit(f"Metal verification failed: {error}")
