import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("plugin_package", ROOT / "scripts/package-openai-plugin.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
from r2_plugin_release import load_release


class PluginPackageTests(unittest.TestCase):
    def test_download_is_reproducible_and_self_contained(self):
        with tempfile.TemporaryDirectory(prefix="voxstudio package ") as tmp:
            base = Path(tmp)
            first = packager.package(ROOT, base / "first")
            second = packager.package(ROOT, base / "second")
            self.assertEqual(first, second)
            artifact = base / "first" / packager.FILENAME
            with zipfile.ZipFile(artifact) as archive:
                self.assertIsNone(archive.testzip())
                names = archive.namelist()
                self.assertTrue(all(name.startswith(packager.FOLDER + "/") and ".." not in Path(name).parts for name in names))
                self.assertFalse(any(name.endswith((".env", ".dmg", ".swift")) or "node_modules" in name for name in names))
                archive.extractall(base / "extracted")
            folder = base / "extracted" / packager.FOLDER
            marketplace = json.loads((folder / ".agents/plugins/marketplace.json").read_text())
            plugin_path = folder / marketplace["plugins"][0]["source"]["path"]
            self.assertEqual(json.loads((plugin_path / "plugin.json").read_text())["version"], first["version"])
            self.assertTrue((plugin_path / ".codex-plugin/plugin.json").is_file())
            self.assertEqual(json.loads((plugin_path / "mcp.json").read_text())["mcpServers"]["voxstudio"]["url"], "http://127.0.0.1:19789/mcp")
            self.assertEqual({p["name"] for p in marketplace["plugins"]}, {"voxstudio", "voxstudio-knowledge"})
            knowledge = folder / "plugins/voxstudio-knowledge"
            self.assertEqual(json.loads((knowledge / "mcp.json").read_text())["mcpServers"]["voxstudio_knowledge"]["url"], "http://127.0.0.1:19789/knowledge/mcp")
            self.assertTrue((knowledge / "skills/knowledge-qa/SKILL.md").is_file())
            for name, version in first["plugins"].items():
                plugin = folder / "plugins" / name
                self.assertEqual(json.loads((plugin / "plugin.json").read_text())["version"], version)
                self.assertEqual(json.loads((plugin / ".codex-plugin/plugin.json").read_text())["version"], version)
            for line in (folder / "FILES.sha256").read_text().splitlines():
                sha, name = line.split("  ", 1)
                self.assertEqual(hashlib.sha256((folder / name).read_bytes()).hexdigest(), sha)

    def test_installer_passes_the_extracted_root_and_plugin_identity(self):
        with tempfile.TemporaryDirectory(prefix="voxstudio installer ") as tmp:
            base = Path(tmp)
            packager.package(ROOT, base)
            with zipfile.ZipFile(base / packager.FILENAME) as archive:
                archive.extractall(base)
            cli = base / "fake cli"
            log = base / "calls.jsonl"
            cli.write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['PLUGIN_TEST_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')\nprint('{}')\n")
            cli.chmod(0o755)
            folder = base / packager.FOLDER
            subprocess.run(["bash", str(folder / "install.sh"), "--cli", str(cli)], check=True,
                           capture_output=True, env={**os.environ, "PLUGIN_TEST_LOG": str(log)})
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(calls, [["plugin", "marketplace", "add", str(folder), "--json"],
                                     ["plugin", "add", "voxstudio@voxstudio-local", "--json"]])

    def test_knowledge_installs_independently_and_missing_option_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            packager.package(ROOT, base)
            with zipfile.ZipFile(base / packager.FILENAME) as archive:
                archive.extractall(base)
            cli = base / "fake-cli"
            log = base / "calls.jsonl"
            cli.write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['PLUGIN_TEST_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')\n")
            cli.chmod(0o755)
            folder = base / packager.FOLDER
            subprocess.run(["bash", str(folder / "install.sh"), "--cli", str(cli), "--plugin", "voxstudio-knowledge"],
                           check=True, capture_output=True, env={**os.environ, "PLUGIN_TEST_LOG": str(log)})
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(calls[-1], ["plugin", "add", "voxstudio-knowledge@voxstudio-local", "--json"])
            result = subprocess.run(["bash", str(folder / "install.sh"), "--plugin"], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_publisher_rejects_tampered_bytes_and_arbitrary_object_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            release = packager.package(ROOT, base)
            path = base / "release.json"
            load_release(path)
            release["object_key"] = "app-releases/voxstudio/channels/stable.json"
            path.write_text(json.dumps(release))
            with self.assertRaises(ValueError):
                load_release(path)
            packager.package(ROOT, base)
            (base / packager.FILENAME).write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                load_release(path)


if __name__ == "__main__":
    unittest.main()
