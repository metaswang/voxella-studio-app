#!/usr/bin/env python3
"""Upload/verify the small OpenAI plugin ZIP; never change DMG channels."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

from r2_release import create_r2_client, load_runtime_environ, resolve_r2_settings

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "830eacc6f0bf33e7119b6c71ed13e03d"
ENDPOINT = f"https://{ACCOUNT}.eu.r2.cloudflarestorage.com"
ORIGIN = "https://assets.voxstudio.me/downloads/voxstudio/"
FILENAME = "VoxStudio-OpenAI-Plugin.zip"


def load_release(path: Path) -> tuple[dict, bytes]:
    release = json.loads(path.read_text())
    if not re.fullmatch(r"\d+\.\d+\.\d+", release["version"]):
        raise ValueError("Invalid plugin version")
    body = (path.parent / FILENAME).read_bytes()
    sha = hashlib.sha256(body).hexdigest()
    suffix = f"plugins/voxstudio/{release['version']}/{sha}/{FILENAME}"
    if (release["name"] != "voxstudio" or release["filename"] != FILENAME
            or release["sha256"] != sha or release["size"] != len(body)
            or release["object_key"] != "app-releases/voxstudio/" + suffix
            or release["url"] != ORIGIN + suffix or not 0 < len(body) <= 2 * 1024 * 1024):
        raise ValueError("Plugin release identity does not match its ZIP")
    return release, body


def upload(release: dict, body: bytes) -> dict:
    from botocore.exceptions import ClientError
    environ = load_runtime_environ(ROOT, [ROOT.parent / "voxella-docker-deploy/.env.prod.myvps2"])
    settings = resolve_r2_settings(environ)
    if settings["account_id"] != ACCOUNT:
        raise ValueError("Expected the existing VoxStudio R2 account")
    settings.update(endpoint=ENDPOINT, bucket="vox", region="auto")
    client = create_r2_client(settings)
    key = release["object_key"]
    try:
        client.put_object(Bucket="vox", Key=key, Body=body, ContentType="application/zip",
                          ContentDisposition=f'attachment; filename="{FILENAME}"',
                          CacheControl="public, max-age=31536000, immutable",
                          Metadata={"sha256": release["sha256"], "plugin-version": release["version"]},
                          IfNoneMatch="*")
    except ClientError as error:
        if error.response["ResponseMetadata"]["HTTPStatusCode"] != 412:
            raise
        # Never overwrite an immutable object. An existing identical ZIP is fine.
    response = client.get_object(Bucket="vox", Key=key)
    downloaded = response["Body"].read()
    response["Body"].close()
    if (downloaded != body or response.get("Metadata", {}).get("sha256") != release["sha256"]
            or response.get("ContentType") != "application/zip"):
        raise ValueError("R2 round-trip verification failed")
    return {"r2_verified": True, "bucket": "vox", "jurisdiction": "eu", "object_key": key}


def verify_cdn(release: dict, body: bytes) -> dict:
    headers = {"User-Agent": "VoxStudioPluginVerify/1.0"}
    with urllib.request.urlopen(urllib.request.Request(release["url"], headers=headers), timeout=30) as response:
        downloaded = response.read()
        if (response.status != 200 or downloaded != body or response.headers.get("Content-Type") != "application/zip"
                or response.headers.get("Content-Length") != str(len(body))
                or response.headers.get("ETag") != f'"{release["sha256"]}"'
                or FILENAME not in response.headers.get("Content-Disposition", "")):
            raise ValueError("Public CDN full-download verification failed")
        cache_control = response.headers.get("Cache-Control")
        if "immutable" not in (cache_control or ""):
            raise ValueError("Immutable CDN cache header is missing")
    with urllib.request.urlopen(urllib.request.Request(release["url"], method="HEAD", headers=headers), timeout=30) as response:
        if response.status != 200 or response.headers.get("Content-Length") != str(len(body)) or response.read():
            raise ValueError("Public CDN HEAD verification failed")
    return {"cdn_verified": True, "url": release["url"], "sha256": release["sha256"],
            "size": len(body), "cache_control": cache_control, "get_status": 200, "head_status": 200}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["upload", "verify"])
    parser.add_argument("--release", type=Path, default=ROOT / ".build/openai-plugin/release.json")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    try:
        release, body = load_release(args.release)
        result = upload(release, body) if args.stage == "upload" else verify_cdn(release, body)
        if args.evidence:
            args.evidence.parent.mkdir(parents=True, exist_ok=True)
            args.evidence.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    except Exception as error:
        # Credentials are never logged, including exception request/response data.
        print(f"Plugin publication failed: {type(error).__name__}")
        raise SystemExit(1)
