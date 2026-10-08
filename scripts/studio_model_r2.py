#!/usr/bin/env python3
"""Publish, verify and retire Studio model snapshots in R2.

Objects live at `{R2__STUDIO_MODEL_PREFIX}/{repository}/{revision}/{path}`, the layout
served by `POST /api/v1/studio-models/snapshot`. Credentials come from an env file
(KEY=VALUE); secret values are never printed.

    uv run --no-project --with boto3 --with requests python scripts/studio_model_r2.py \
        --env-file ../voxella-docker-deploy/.env.prod.myvps2 <command> ...

Commands
  publish        Upload files, then verify remote size, ETag (MD5) and SHA-256 metadata.
  verify         Re-check already published files against local copies.
  retire         Delete every object under a repository prefix (optionally limited to
                 revisions). Idempotent; writes a JSON manifest of deleted objects/results.
  purge-cdn      Purge the CDN chunk cache for a repository by URL prefix, so cached
                 chunks of every ETag and query variant are dropped.
  check-retired  Confirm the snapshot API no longer serves a retired repository@revision
                 and that a previously issued download URL fails.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


class Config:
    def __init__(self, env: dict[str, str]):
        self.env = env
        self.bucket = env["R2__BUCKET"]
        self.prefix = env.get("R2__STUDIO_MODEL_PREFIX", "studio-models").strip("/") or "studio-models"
        account = env.get("R2__ACCOUNT_ID", "")
        self.endpoint = env.get("R2__API_BASE_URL") or env.get("R2__ENDPOINT") or f"https://{account}.r2.cloudflarestorage.com"
        self.cdn_base = env.get("CF__MODEL_CDN_BASE_URL", "").rstrip("/")

    def client(self):
        import boto3
        from botocore.config import Config as BotoConfig

        return boto3.client(
            "s3",
            endpoint_url=self.endpoint,
            region_name=self.env.get("R2__REGION") or "auto",
            aws_access_key_id=self.env["R2__ACCESS_KEY_ID"],
            aws_secret_access_key=self.env["R2__SECRET_ACCESS_KEY"],
            config=BotoConfig(signature_version="s3v4", retries={"max_attempts": 5, "mode": "standard"}),
        )

    def repository_prefix(self, repository: str) -> str:
        return f"{self.prefix}/{repository.strip('/')}/"

    def object_key(self, repository: str, revision: str, path: str) -> str:
        return f"{self.repository_prefix(repository)}{revision}/{path}"


def digests(path: Path) -> tuple[str, str, int]:
    md5 = hashlib.md5()
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            md5.update(block)
            sha.update(block)
            size += len(block)
    return md5.hexdigest(), sha.hexdigest(), size


def verify_object(client, config: Config, key: str, local: Path) -> dict:
    md5, sha, size = digests(local)
    head = client.head_object(Bucket=config.bucket, Key=key)
    etag = head["ETag"].strip('"')
    remote_sha = head.get("Metadata", {}).get("sha256")
    ok = head["ContentLength"] == size and etag == md5 and remote_sha == sha
    return {"key": key, "size": size, "sha256": sha, "remote_size": head["ContentLength"],
            "remote_etag": etag, "remote_sha256": remote_sha, "ok": ok}


def cmd_publish(config: Config, args) -> int:
    client = config.client()
    results = []
    for name in args.files:
        local = Path(args.source) / name
        md5, sha, size = digests(local)
        key = config.object_key(args.repository, args.revision, name)
        with local.open("rb") as body:
            # Single-part PUT keeps the ETag equal to the MD5 (files here are < 5 GB).
            client.put_object(
                Bucket=config.bucket, Key=key, Body=body, ContentLength=size,
                ContentMD5=base64.b64encode(bytes.fromhex(md5)).decode(),
                ContentType="application/octet-stream", Metadata={"sha256": sha},
            )
        result = verify_object(client, config, key, local)
        results.append(result)
        print(f"{'OK ' if result['ok'] else 'BAD'} {key} {size} sha256={sha}")
    write_manifest(args.manifest, {"command": "publish", "repository": args.repository,
                                   "revision": args.revision, "objects": results})
    return 0 if all(item["ok"] for item in results) else 1


def cmd_verify(config: Config, args) -> int:
    client = config.client()
    results = [verify_object(client, config, config.object_key(args.repository, args.revision, name),
                             Path(args.source) / name) for name in args.files]
    for item in results:
        print(f"{'OK ' if item['ok'] else 'BAD'} {item['key']} remote={item['remote_size']} sha256={item['remote_sha256']}")
    write_manifest(args.manifest, {"command": "verify", "objects": results})
    return 0 if all(item["ok"] for item in results) else 1


def list_objects(client, config: Config, prefix: str) -> list[dict]:
    objects, token = [], None
    while True:
        params = {"Bucket": config.bucket, "Prefix": prefix, "MaxKeys": 1000}
        if token:
            params["ContinuationToken"] = token
        page = client.list_objects_v2(**params)
        objects += page.get("Contents") or []
        if not page.get("IsTruncated"):
            return objects
        token = page.get("NextContinuationToken")


def cmd_retire(config: Config, args) -> int:
    client = config.client()
    base = config.repository_prefix(args.repository)
    prefixes = [f"{base}{revision}/" for revision in args.revisions] if args.revisions else [base]
    found = [item for prefix in prefixes for item in list_objects(client, config, prefix)]
    deleted, errors = [], []
    if not args.dry_run:
        for start in range(0, len(found), 1000):
            batch = found[start:start + 1000]
            response = client.delete_objects(
                Bucket=config.bucket,
                Delete={"Objects": [{"Key": item["Key"]} for item in batch], "Quiet": False},
            )
            deleted += [item["Key"] for item in response.get("Deleted") or []]
            errors += response.get("Errors") or []
    remaining = [item["Key"] for prefix in prefixes for item in list_objects(client, config, prefix)]
    manifest = {
        "command": "retire", "repository": args.repository, "prefixes": prefixes, "dry_run": args.dry_run,
        "found": [{"key": item["Key"], "size": item["Size"], "etag": item["ETag"].strip('"')} for item in found],
        "deleted": deleted, "errors": errors, "remaining": remaining,
    }
    write_manifest(args.manifest, manifest)
    print(f"found={len(found)} deleted={len(deleted)} errors={len(errors)} remaining={len(remaining)} dry_run={args.dry_run}")
    return 0 if (args.dry_run or (not errors and not remaining)) else 1


def cmd_purge_cdn(config: Config, args) -> int:
    import requests

    if not config.cdn_base:
        print("CF__MODEL_CDN_BASE_URL is not configured", file=sys.stderr)
        return 2
    host_path = config.cdn_base.split("://", 1)[-1]
    # Cache keys are `{cdn}/models/v1/{key}?v=2&etag=…`; prefix purges ignore the query.
    prefix = f"{host_path}/models/v1/{config.repository_prefix(args.repository)}"
    zone = args.zone_id or config.env.get("CF__ZONE_ID") or config.env.get("CF_ZONE_ID")
    headers = {"Content-Type": "application/json"}
    token = config.env.get("CF_API_TOKEN") or config.env.get("CF__API_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    else:
        headers["X-Auth-Key"] = config.env.get("CF_API_KEY", "")
        headers["X-Auth-Email"] = args.email or config.env.get("CF_API_EMAIL", "")
    api = "https://api.cloudflare.com/client/v4"
    if not zone:
        zone_name = ".".join(host_path.split("/")[0].split(".")[-2:])
        response = requests.get(f"{api}/zones", params={"name": zone_name}, headers=headers, timeout=30)
        response.raise_for_status()
        zones = response.json().get("result") or []
        if not zones:
            print(f"zone {zone_name} not found", file=sys.stderr)
            return 2
        zone = zones[0]["id"]
    response = requests.post(f"{api}/zones/{zone}/purge_cache", json={"prefixes": [prefix]}, headers=headers, timeout=30)
    body = response.json()
    write_manifest(args.manifest, {"command": "purge-cdn", "prefix": prefix, "status": response.status_code,
                                   "success": body.get("success"), "errors": body.get("errors")})
    print(f"purge prefix={prefix} status={response.status_code} success={body.get('success')}")
    return 0 if body.get("success") else 1


def cmd_check_retired(config: Config, args) -> int:
    import requests

    url = f"{args.api_base.rstrip('/')}/api/v1/studio-models/snapshot"
    response = requests.post(url, json={"repository": args.repository, "revision": args.revision,
                                        "matching": ["*"]}, timeout=30)
    checks = {"snapshot_status": response.status_code, "snapshot_retired": response.status_code == 404}
    for old in args.old_urls or []:
        status = requests.get(old, headers={"Range": "bytes=0-0"}, timeout=30).status_code
        checks.setdefault("old_urls", []).append({"status": status, "failed": status >= 400})
    ok = checks["snapshot_retired"] and all(item["failed"] for item in checks.get("old_urls", []))
    write_manifest(args.manifest, {"command": "check-retired", "repository": args.repository,
                                   "revision": args.revision, **checks, "ok": ok})
    print(json.dumps({**checks, "ok": ok}))
    return 0 if ok else 1


def write_manifest(path: str | None, payload: dict) -> None:
    if not path:
        return
    payload = {"generated_at": datetime.now(timezone.utc).isoformat(), **payload}
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", required=True, type=Path)
    sub = parser.add_subparsers(dest="command", required=True)

    for name in ("publish", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--repository", required=True)
        command.add_argument("--revision", required=True)
        command.add_argument("--source", required=True)
        command.add_argument("--files", nargs="+", required=True)
        command.add_argument("--manifest")

    retire = sub.add_parser("retire")
    retire.add_argument("--repository", required=True)
    retire.add_argument("--revisions", nargs="*")
    retire.add_argument("--manifest", required=True)
    retire.add_argument("--dry-run", action="store_true")

    purge = sub.add_parser("purge-cdn")
    purge.add_argument("--repository", required=True)
    purge.add_argument("--zone-id")
    purge.add_argument("--email")
    purge.add_argument("--manifest")

    check = sub.add_parser("check-retired")
    check.add_argument("--repository", required=True)
    check.add_argument("--revision", required=True)
    check.add_argument("--api-base", required=True)
    check.add_argument("--old-urls", nargs="*")
    check.add_argument("--manifest")

    args = parser.parse_args()
    config = Config(load_env(args.env_file))
    handler = {
        "publish": cmd_publish, "verify": cmd_verify, "retire": cmd_retire,
        "purge-cdn": cmd_purge_cdn, "check-retired": cmd_check_retired,
    }[args.command]
    started = time.monotonic()
    code = handler(config, args)
    print(f"{args.command} finished in {time.monotonic() - started:.1f}s exit={code}")
    return code


if __name__ == "__main__":
    sys.exit(main())
