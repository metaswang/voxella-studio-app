#!/usr/bin/env python3
"""Build-cache regression tests; no Metal hardware or downloads required."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import build_metal as metal
import verify_metal as verify


class MetalBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "test.metal"
        self.source.write_text("kernel void test() {}")
        self.header = self.root / "test.h"
        self.header.write_text("// header")
        self.output = self.root / "test.metallib"
        self.tools = {"compiler": "compiler 1", "sdk_version": "26.0"}
        self.commands = []

    def run_tool(self, args, **kwargs):
        self.commands.append(args)
        Path(args[args.index("-o") + 1]).write_bytes(b"compiled")

    def build(self):
        with patch.object(metal.subprocess, "run", side_effect=self.run_tool):
            metal.build([self.source], [self.source, self.header], self.output, self.tools)

    def test_flags_and_cache_hit(self):
        self.build()
        self.assertIn("-mmacosx-version-min=15.0", self.commands[0])
        self.assertIn("-std=metal3.2", self.commands[0])
        self.commands.clear()
        self.build()
        self.assertEqual(self.commands, [])

    def test_legacy_file_without_receipt_rebuilds(self):
        self.output.write_bytes(b"old metal4 library")
        self.build()
        self.assertEqual(self.output.read_bytes(), b"compiled")

    def test_changes_invalidate_cache(self):
        self.build()
        for change in (lambda: self.header.write_text("// changed header"),
                       lambda: self.source.write_text("kernel void changed() {}"),
                       lambda: self.tools.update(compiler="compiler 2"),
                       lambda: self.tools.update(sdk_version="26.1"),
                       lambda: self.output.write_bytes(b"damaged")):
            self.commands.clear()
            change()
            self.build()
            self.assertTrue(self.commands)

    def test_flags_invalidate_cache(self):
        self.build()
        self.commands.clear()
        with patch.object(metal, "BASE_FLAGS", metal.BASE_FLAGS + ["-gline-tables-only"]):
            self.build()
        self.assertTrue(self.commands)

    def test_failed_compile_preserves_previous_library_and_receipt(self):
        self.build()
        receipt = self.output.with_suffix(".build.json").read_bytes()
        self.source.write_text("invalid source")
        with patch.object(metal.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "metal")):
            with self.assertRaises(subprocess.CalledProcessError):
                metal.build([self.source], [self.source, self.header], self.output, self.tools)
        self.assertEqual(self.output.read_bytes(), b"compiled")
        self.assertEqual(self.output.with_suffix(".build.json").read_bytes(), receipt)

    def test_added_or_removed_source_changes_fingerprint(self):
        first = metal.fingerprint([self.source], metal.BASE_FLAGS, self.tools)
        self.assertNotEqual(first, metal.fingerprint([self.source, self.header], metal.BASE_FLAGS, self.tools))

    def make_resources(self):
        paths = [p.stem + ".metallib" for p in (ROOT / "Metal").glob("*.metal")]
        paths.append("mlx-swift_Cmlx.bundle/default.metallib")
        entries = []
        for name in paths:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"shader")
            entries.append({"path": name, "bytes": 6, "sha256": metal.sha(path)})
        manifest = {"schema": 1, **metal.policy(), "libraries": entries}
        (self.root / "metal-build.json").write_text(json.dumps(manifest))

    def test_package_rejects_changed_shader(self):
        self.make_resources()
        verify.verify_resources(self.root, "15.0")
        (self.root / "Grain.metallib").write_bytes(b"broken")
        with self.assertRaisesRegex(ValueError, "differs"):
            verify.verify_resources(self.root, "15.0")

    def test_package_rejects_missing_or_extra_library(self):
        self.make_resources()
        extra = self.root / "duplicate.metallib"
        extra.write_bytes(b"shader")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            verify.verify_resources(self.root, "15.0")
        extra.unlink()
        (self.root / "Grain.metallib").unlink()
        with self.assertRaisesRegex(ValueError, "Missing"):
            verify.verify_resources(self.root, "15.0")

    def test_package_rejects_newer_language(self):
        self.make_resources()
        path = self.root / "metal-build.json"
        data = json.loads(path.read_text())
        data["language"] = "metal4.0"
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "policy"):
            verify.verify_resources(self.root, "15.0")


if __name__ == "__main__":
    unittest.main()
