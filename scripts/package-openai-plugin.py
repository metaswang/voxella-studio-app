#!/usr/bin/env python3
"""Build a reproducible, self-contained local OpenAI marketplace ZIP."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FOLDER = "VoxStudio-OpenAI-Plugin"
FILENAME = FOLDER + ".zip"
ORIGIN = "https://assets.voxstudio.me/downloads/voxstudio"


def package(root: Path, output: Path) -> dict:
    files = {}
    plugins = []
    plugin_versions = {}
    for plugin_name, skills in [("voxstudio", ["onboarding", "media-workflow", "session-retrieval", "file-editing", "video-editing", "knowledge-qa"])]:
        plugin = root / "Plugins" / plugin_name
        manifest = json.loads((plugin / "plugin.json").read_text())
        plugin_versions[plugin_name] = manifest["version"]
        config = json.loads((plugin / "mcp.json").read_text())
        expected_key = "voxstudio" if plugin_name == "voxstudio" else "voxstudio_knowledge"
        expected_path = "/app/mcp"
        assert manifest["name"] == plugin_name
        assert config["mcpServers"][expected_key]["url"] == "http://127.0.0.1:19789" + expected_path
        prefix = "plugins/" + plugin_name + "/"
        assert (plugin/'assets/icon.png').read_bytes() == (root/'Sources/VoxstudioPro/Resources/AppIcon.png').read_bytes(), 'Run scripts/sync-mcp-branding.py before packaging'
        for name in ["plugin.json", "mcp.json", "assets/icon.png"]:
            files[prefix + name] = (plugin / name).read_bytes()
        # Explicit reviewed whitelist; no arbitrary skills or repo files enter the archive.
        for skill in skills:
            name = f"skills/{skill}/SKILL.md"
            files[prefix + name] = (plugin / name).read_bytes()
        legacy = {k: v for k, v in manifest.items() if k != "$schema"}
        legacy.update(skills="./skills/", mcpServers="./.mcp.json", interface=manifest["extensions"]["com.openai"]["interface"])
        files[prefix + ".codex-plugin/plugin.json"] = encode(legacy)
        files[prefix + ".mcp.json"] = encode({"mcpServers": {k: {**v, "type": "http"} for k, v in config["mcpServers"].items()}})
        plugins.append({"name": plugin_name, "source": {"source": "local", "path": "./plugins/" + plugin_name},
                        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}, "category": "Productivity"})
    manifest = json.loads((root / "Plugins/voxstudio/plugin.json").read_text())
    files[".agents/plugins/marketplace.json"] = encode({"name": "voxstudio-local", "interface": {"displayName": "VoxStudio Local"}, "plugins": plugins})
    files["README.md"] = (root / "docs/plugins/openai-plugin-install.md").read_bytes()
    files["install.sh"] = (root / "scripts/openai-plugin-install.sh").read_bytes()
    files["install.py"] = (root / "scripts/openai-plugin-install.py").read_bytes()
    files["FILES.sha256"] = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(files.items())
    ).encode()
    output.mkdir(parents=True, exist_ok=True)
    artifact = output / FILENAME
    with zipfile.ZipFile(artifact, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(f"{FOLDER}/{name}", (2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 if name == "install.sh" else 0o100644) << 16
            archive.writestr(entry, data, compresslevel=9)
    sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
    version = manifest["version"]
    key = f"plugins/voxstudio/{version}/{sha}/{FILENAME}"
    result = {"name": manifest["name"], "version": version, "filename": FILENAME,
              "size": artifact.stat().st_size, "sha256": sha, "file_count": len(files),
              "object_key": "app-releases/voxstudio/" + key, "url": ORIGIN + "/" + key,
              "plugins": plugin_versions}
    (output / "release.json").write_bytes(encode(result))
    return result


def encode(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/openai-plugin")
    print(json.dumps(package(ROOT, parser.parse_args().output), indent=2))
