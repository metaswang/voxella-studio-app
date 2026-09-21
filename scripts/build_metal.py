#!/usr/bin/env python3
"""Build one portable Metal library per purpose for macOS 15 / Apple silicon.

The cache is private build state, never an app resource. No dependency checkout
is patched; bundle.sh and the SwiftPM CI plugin both use this entry point.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGE = "metal3.2"
MINIMUM = "15.0"
BASE_FLAGS = [f"-mmacosx-version-min={MINIMUM}", f"-std={LANGUAGE}"]
MLX_FLAGS = ["-x", "metal", "-Wall", "-Wextra", "-fno-fast-math",
             "-Wno-c++17-extensions", "-Wno-c++20-extensions"]


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def capture(args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True, **kwargs).strip()


def policy():
    with (ROOT / "Sources/PalmierPro/Resources/Info.plist").open("rb") as stream:
        minimum = plistlib.load(stream)["LSMinimumSystemVersion"]
    if minimum != MINIMUM:
        raise ValueError("Review Metal compatibility policy when changing LSMinimumSystemVersion")
    return {"minimum_macos": minimum, "language": LANGUAGE, "architecture": "arm64"}


def toolchain():
    # Include actual compiler identity, not only the selected Xcode path: the
    # optional Metal component can be updated independently of Xcode.
    info = {
        "compiler": capture(["xcrun", "-sdk", "macosx", "metal", "-v"]),
        "compiler_path": capture(["xcrun", "-sdk", "macosx", "--find", "metal"]),
        "sdk_path": capture(["xcrun", "-sdk", "macosx", "--show-sdk-path"]),
        "sdk_version": capture(["xcrun", "-sdk", "macosx", "--show-sdk-version"]),
        "sdk_build": capture(["xcrun", "-sdk", "macosx", "--show-sdk-build-version"]),
        "xcode": capture(["xcodebuild", "-version"]),
    }
    version = capture(["xcrun", "-sdk", "macosx", "metal", *BASE_FLAGS,
                       "-E", "-x", "metal", "-P", "-"], input="__METAL_VERSION__\n")
    if version.splitlines()[-1].strip() != "320":
        raise ValueError(f"Expected Metal 3.2 for macOS 15, compiler reported {version!r}")
    return info


def fingerprint(dependencies, flags, tools):
    inputs = {"policy": policy(), "flags": flags, "tools": tools,
              "builder": sha(__file__),
              "sources": [(str(p), sha(p)) for p in sorted(set(dependencies))]}
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def cached(output, key):
    try:
        receipt = json.loads(output.with_suffix(".build.json").read_text())
        return receipt["key"] == key and receipt["sha256"] == sha(output)
    except (OSError, ValueError, KeyError):
        return False


def build(sources, dependencies, output, tools, *, ci=False, includes=(), jobs=2):
    flags = BASE_FLAGS + (["-fcikernel"] if ci else MLX_FLAGS)
    include_flags = [arg for path in includes for arg in ("-I", str(path))]
    key = fingerprint(dependencies, flags + include_flags, tools)
    output = Path(output)
    if cached(output, key):
        print(f"Metal cache verified: {output}", flush=True)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    print(f"Compiling {len(sources)} sources -> {output} ({LANGUAGE}, macOS {MINIMUM})", flush=True)
    # A failed build leaves the last complete library intact. Receipt is written
    # only after linking succeeds; a stale or corrupted output is never reused.
    with tempfile.TemporaryDirectory(prefix="metal-", dir=output.parent) as temp:
        temp = Path(temp)

        def compile_one(item):
            index, source = item
            air = temp / f"{index}.air"
            subprocess.run(["xcrun", "-sdk", "macosx", "metal", *flags, *include_flags,
                            "-c", str(source), "-o", str(air)], check=True)
            return air

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            airs = list(pool.map(compile_one, enumerate(sources)))
        linked = temp / "library.metallib"
        subprocess.run(["xcrun", "-sdk", "macosx", "metallib",
                        *(["-cikernel"] if ci else []), *map(str, airs), "-o", str(linked)], check=True)
        if not linked.stat().st_size:
            raise ValueError("Metal linker produced an empty library")
        receipt = temp / "receipt.json"
        receipt.write_text(json.dumps({"key": key, "sha256": sha(linked),
                                       **policy(), "tools": tools}, indent=2) + "\n")
        os.replace(linked, output)
        os.replace(receipt, output.with_suffix(".build.json"))


def build_mlx(output, tools, jobs):
    mlx = ROOT / ".build/checkouts/mlx-swift/Source/Cmlx/mlx"
    kernels = mlx / "mlx/backend/metal/kernels"
    # NAX kernels require newer GPU/Metal capabilities and are not part of the
    # M1–M4 baseline (same exclusion as speech-swift's existing offline build).
    sources = sorted(p for p in kernels.rglob("*.metal") if not p.name.endswith("_nax.metal"))
    if not sources:
        raise ValueError("MLX kernels missing; resolve SwiftPM dependencies first")
    dependencies = sources + list(mlx.rglob("*.h"))
    build(sources, dependencies, output, tools, includes=[kernels, mlx], jobs=jobs)


def prepare(output, tools, jobs):
    output.mkdir(parents=True, exist_ok=True)
    build_mlx(output / "mlx.metallib", tools, jobs)
    entries = [(output / "mlx.metallib", "mlx-swift_Cmlx.bundle/default.metallib")]
    for source in sorted((ROOT / "Metal").glob("*.metal")):
        target = output / f"{source.stem}.metallib"
        build([source], list((ROOT / "Metal").iterdir()), target, tools, ci=True, jobs=jobs)
        entries.append((target, target.name))
    manifest = {"schema": 1, **policy(),
                "toolchain": {k: v for k, v in tools.items() if not k.endswith("_path")},
                "libraries": [{"path": relative, "sha256": sha(path), "bytes": path.stat().st_size}
                              for path, relative in entries]}
    (output / "metal-build.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["preflight", "mlx", "ci", "prepare"])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    policy()
    tools = toolchain()
    if args.mode == "preflight":
        print(f"Metal ready: {LANGUAGE}, macOS {MINIMUM}, arm64 (M1–M4 baseline)")
        return
    if args.output is None:
        parser.error("--output is required")
    if args.mode == "mlx":
        build_mlx(args.output, tools, args.jobs)
    elif args.mode == "ci":
        if args.source is None:
            parser.error("ci requires --source")
        build([args.source], list(args.source.parent.glob("*.metal")) + list(args.source.parent.glob("*.h")),
              args.output, tools, ci=True, jobs=args.jobs)
    else:
        prepare(args.output, tools, args.jobs)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output)
        raise SystemExit(f"Metal build failed: {error}")
