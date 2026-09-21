#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from typing import Any, Callable, Mapping


CHUNK_SIZE_BYTES = 32 * 1024 * 1024
PUBLIC_ORIGIN = "https://assets.voxstudio.me"
PUBLIC_USER_AGENT = "VoxStudioReleaseVerify/1.0"
OBJECT_PREFIX = "app-releases/voxstudio"
DMG_NAME = "VoxStudio.dmg"
DEFAULT_BUCKET = "vox"
DEFAULT_ARCH = "arm64"
DEFAULT_MINIMUM_SYSTEM_VERSION = "15.0"

STAGES = ("prepare", "upload", "verify", "cache-check", "promote", "postcheck")
# Conservative byte limit; do not silently publish an uncacheable artifact.
MAX_CACHEABLE_BYTES = 512_000_000


@dataclass(frozen=True)
class ReleaseChunk:
    index: int
    offset: int
    length: int
    sha256: str


@dataclass(frozen=True)
class ReleaseManifest:
    version: str
    build: str
    arch: str
    minimumSystemVersion: str
    fileName: str
    size: int
    sha256: str
    sparkleEdSignature: str
    chunkSize: int
    chunks: list[ReleaseChunk]


@dataclass(frozen=True)
class StablePointer:
    version: str
    build: str
    sha256: str
    releasePath: str
    dmgUrl: str
    appcastPath: str


@dataclass(frozen=True)
class PreparedRelease:
    version: str
    build: str
    sha256: str
    size: int
    staging_dir: Path
    dmg_path: Path
    manifest_path: Path
    appcast_path: Path
    chunk_paths: list[Path]
    identity: str
    versioned_url: str
    latest_url: str
    appcast_url: str


class PublishError(RuntimeError):
    pass


def versioned_dmg_path(version: str, build: str, sha256: str) -> str:
    return f"/downloads/voxstudio/releases/{version}-{build}/{sha256}/{DMG_NAME}"


def versioned_dmg_url(version: str, build: str, sha256: str, origin: str = PUBLIC_ORIGIN) -> str:
    return f"{origin.rstrip('/')}{versioned_dmg_path(version, build, sha256)}"


def release_identity(version: str, build: str, sha256: str) -> str:
    return f"releases/{version}-{build}/{sha256}"


def object_key(identity: str, relative: str, prefix: str = OBJECT_PREFIX) -> str:
    return "/".join(part.strip("/") for part in (prefix, identity, relative) if part)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bytes_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def split_chunks(path: Path, chunk_size: int = CHUNK_SIZE_BYTES) -> list[ReleaseChunk]:
    size = path.stat().st_size
    if chunk_size < 1:
        raise PublishError("chunk size must be positive")
    if size == 0:
        return []
    chunks: list[ReleaseChunk] = []
    offset = 0
    index = 0
    with path.open("rb") as handle:
        while offset < size:
            data = handle.read(min(chunk_size, size - offset))
            if not data:
                break
            chunks.append(
                ReleaseChunk(
                    index=index,
                    offset=offset,
                    length=len(data),
                    sha256=bytes_sha256(data),
                )
            )
            offset += len(data)
            index += 1
    if offset != size:
        raise PublishError(f"failed to read complete DMG: expected {size} bytes, got {offset}")
    return chunks


def build_manifest(
    *,
    version: str,
    build: str,
    dmg_path: Path,
    signature: str,
    arch: str = DEFAULT_ARCH,
    minimum_system_version: str = DEFAULT_MINIMUM_SYSTEM_VERSION,
    chunk_size: int = CHUNK_SIZE_BYTES,
) -> ReleaseManifest:
    size = dmg_path.stat().st_size
    sha256 = file_sha256(dmg_path)
    chunks = split_chunks(dmg_path, chunk_size)
    return ReleaseManifest(
        version=version,
        build=str(build),
        arch=arch,
        minimumSystemVersion=minimum_system_version,
        fileName=DMG_NAME,
        size=size,
        sha256=sha256,
        sparkleEdSignature=signature,
        chunkSize=chunk_size,
        chunks=chunks,
    )


def build_appcast(
    manifest: ReleaseManifest,
    *,
    origin: str = PUBLIC_ORIGIN,
    pub_date: datetime | None = None,
) -> str:
    published = format_datetime(pub_date or datetime.now(timezone.utc))
    url = versioned_dmg_url(manifest.version, manifest.build, manifest.sha256, origin)
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>VoxStudio</title>
        <link>{origin.rstrip('/')}/downloads/voxstudio/appcast.xml</link>
        <description>VoxStudio updates</description>
        <language>en</language>
        <item>
            <title>Version {manifest.version}</title>
            <pubDate>{published}</pubDate>
            <sparkle:version>{manifest.build}</sparkle:version>
            <sparkle:shortVersionString>{manifest.version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{manifest.minimumSystemVersion}</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure
                url="{url}"
                length="{manifest.size}"
                type="application/octet-stream"
                sparkle:edSignature="{manifest.sparkleEdSignature}"/>
        </item>
    </channel>
</rss>
"""


def build_stable_pointer(manifest: ReleaseManifest) -> StablePointer:
    identity = release_identity(manifest.version, manifest.build, manifest.sha256)
    return StablePointer(
        version=manifest.version,
        build=manifest.build,
        sha256=manifest.sha256,
        releasePath=identity,
        dmgUrl=versioned_dmg_path(manifest.version, manifest.build, manifest.sha256),
        appcastPath=f"{identity}/appcast.xml",
    )


def stable_write_condition(existing_etag: str | None) -> dict[str, str]:
    if existing_etag:
        return {"if_match": existing_etag}
    return {"if_none_match": "*"}


def write_chunk_files(dmg_path: Path, destination: Path, chunks: list[ReleaseChunk]) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    with dmg_path.open("rb") as handle:
        for chunk in chunks:
            path = destination / f"{chunk.index:06d}.bin"
            handle.seek(chunk.offset)
            data = handle.read(chunk.length)
            if len(data) != chunk.length or bytes_sha256(data) != chunk.sha256:
                raise PublishError(f"chunk {chunk.index} changed while preparing")
            path.write_bytes(data)
            paths.append(path)
    return paths


def link_or_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        destination.unlink()
    try:
        os.link(source, destination)
    except OSError:
        import shutil

        shutil.copy2(source, destination)


def manifest_to_dict(manifest: ReleaseManifest) -> dict[str, Any]:
    payload = asdict(manifest)
    return payload


def prepare_release(
    *,
    dmg_path: Path,
    staging_root: Path,
    version: str,
    build: str,
    signature: str,
    arch: str = DEFAULT_ARCH,
    minimum_system_version: str = DEFAULT_MINIMUM_SYSTEM_VERSION,
    origin: str = PUBLIC_ORIGIN,
) -> PreparedRelease:
    if not dmg_path.is_file():
        raise PublishError(f"DMG not found: {dmg_path}")
    if not signature.strip():
        raise PublishError("Sparkle signature is required")

    manifest = build_manifest(
        version=version,
        build=build,
        dmg_path=dmg_path,
        signature=signature.strip(),
        arch=arch,
        minimum_system_version=minimum_system_version,
    )
    identity = release_identity(manifest.version, manifest.build, manifest.sha256)
    staging_dir = staging_root / f"{manifest.version}-{manifest.build}" / manifest.sha256
    staging_dir.mkdir(parents=True, exist_ok=True)

    staged_dmg = staging_dir / DMG_NAME
    link_or_copy(dmg_path, staged_dmg)
    chunk_paths = write_chunk_files(staged_dmg, staging_dir / "chunks", manifest.chunks)
    manifest_path = staging_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest_to_dict(manifest), indent=2) + "\n")
    appcast_path = staging_dir / "appcast.xml"
    appcast_path.write_text(build_appcast(manifest, origin=origin))
    pointer = build_stable_pointer(manifest)
    (staging_dir / "stable.json").write_text(json.dumps(asdict(pointer), indent=2) + "\n")
    state_path = staging_root / "state.json"
    write_state(
        state_path,
        {
            "stage": "prepare",
            "identity": identity,
            "version": manifest.version,
            "build": manifest.build,
            "sha256": manifest.sha256,
            "size": manifest.size,
            "staging_dir": str(staging_dir),
            "completed": ["prepare"],
        },
    )
    return PreparedRelease(
        version=manifest.version,
        build=manifest.build,
        sha256=manifest.sha256,
        size=manifest.size,
        staging_dir=staging_dir,
        dmg_path=staged_dmg,
        manifest_path=manifest_path,
        appcast_path=appcast_path,
        chunk_paths=chunk_paths,
        identity=identity,
        versioned_url=versioned_dmg_url(manifest.version, manifest.build, manifest.sha256, origin),
        latest_url=f"{origin.rstrip('/')}/downloads/voxstudio/{DMG_NAME}",
        appcast_url=f"{origin.rstrip('/')}/downloads/voxstudio/appcast.xml",
    )


def write_state(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f".tmp-{os.getpid()}")
    temporary.write_text(json.dumps(dict(payload), indent=2) + "\n")
    temporary.replace(path)


def load_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    return json.loads(path.read_text())


def load_prepared(staging_dir: Path, origin: str = PUBLIC_ORIGIN) -> PreparedRelease:
    manifest = json.loads((staging_dir / "manifest.json").read_text())
    identity = release_identity(manifest["version"], manifest["build"], manifest["sha256"])
    chunk_dir = staging_dir / "chunks"
    chunk_paths = sorted(chunk_dir.glob("*.bin")) if chunk_dir.is_dir() else []
    return PreparedRelease(
        version=manifest["version"],
        build=manifest["build"],
        sha256=manifest["sha256"],
        size=manifest["size"],
        staging_dir=staging_dir,
        dmg_path=staging_dir / DMG_NAME,
        manifest_path=staging_dir / "manifest.json",
        appcast_path=staging_dir / "appcast.xml",
        chunk_paths=chunk_paths,
        identity=identity,
        versioned_url=versioned_dmg_url(manifest["version"], manifest["build"], manifest["sha256"], origin),
        latest_url=f"{origin.rstrip('/')}/downloads/voxstudio/{DMG_NAME}",
        appcast_url=f"{origin.rstrip('/')}/downloads/voxstudio/appcast.xml",
    )


def load_dotenv(path: Path, environ: dict[str, str]) -> None:
    if not path.is_file():
        return
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in environ:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        environ[key] = value


def resolve_r2_settings(environ: Mapping[str, str]) -> dict[str, str]:
    account_id = environ.get("R2__ACCOUNT_ID") or environ.get("R2_ACCOUNT_ID") or ""
    access_key = environ.get("R2__ACCESS_KEY_ID") or environ.get("R2_ACCESS_KEY_ID") or ""
    secret = environ.get("R2__SECRET_ACCESS_KEY") or environ.get("R2_SECRET_ACCESS_KEY") or ""
    bucket = environ.get("R2__BUCKET") or environ.get("R2_BUCKET") or DEFAULT_BUCKET
    endpoint = environ.get("R2__API_BASE_URL") or environ.get("R2_API_BASE_URL") or ""
    region = environ.get("R2__REGION") or environ.get("R2_REGION") or "auto"
    if not account_id or not access_key or not secret:
        raise PublishError("R2 credentials are missing; set R2__ACCOUNT_ID, R2__ACCESS_KEY_ID, and R2__SECRET_ACCESS_KEY")
    if not endpoint:
        endpoint = f"https://{account_id}.r2.cloudflarestorage.com"
    return {
        "account_id": account_id,
        "access_key": access_key,
        "secret": secret,
        "bucket": bucket,
        "endpoint": endpoint,
        "region": region,
    }


def create_r2_client(settings: Mapping[str, str]) -> Any:
    try:
        import boto3
        from botocore.config import Config
    except ImportError as error:
        raise PublishError("boto3 is required; run via uv run --with boto3") from error

    return boto3.client(
        "s3",
        endpoint_url=settings["endpoint"],
        aws_access_key_id=settings["access_key"],
        aws_secret_access_key=settings["secret"],
        region_name=settings["region"],
        config=Config(
            signature_version="s3v4",
            connect_timeout=30,
            read_timeout=120,
            retries={"max_attempts": 8, "mode": "standard"},
        ),
    )


def existing_object_sha256(client: Any, bucket: str, key: str) -> str | None:
    try:
        head = client.head_object(Bucket=bucket, Key=key)
    except Exception as error:
        code = getattr(error, "response", {}).get("Error", {}).get("Code")
        if code in {"404", "NoSuchKey", "NotFound"}:
            return None
        raise
    metadata = {str(name).lower(): str(value) for name, value in (head.get("Metadata") or {}).items()}
    digest = metadata.get("sha256")
    if digest:
        return digest
    body = client.get_object(Bucket=bucket, Key=key)["Body"]
    hasher = hashlib.sha256()
    for block in iter(lambda: body.read(1024 * 1024), b""):
        hasher.update(block)
    return hasher.hexdigest()


def put_object(
    client: Any,
    *,
    bucket: str,
    key: str,
    body: bytes | Path,
    content_type: str,
    sha256: str,
    if_match: str | None = None,
    if_none_match: str | None = None,
) -> None:
    extra: dict[str, Any] = {
        "Bucket": bucket,
        "Key": key,
        "ContentType": content_type,
        "Metadata": {"sha256": sha256},
    }
    if isinstance(body, Path):
        extra["Body"] = body.read_bytes() if body.stat().st_size < 8 * 1024 * 1024 else body.open("rb")
    else:
        extra["Body"] = body

    def inject(request: Any, **_kwargs: Any) -> None:
        if if_none_match:
            request.headers["If-None-Match"] = if_none_match
        if if_match:
            request.headers["If-Match"] = if_match

    client.meta.events.register("before-sign.s3.PutObject", inject)
    try:
        client.put_object(**extra)
    except Exception as error:
        code = getattr(error, "response", {}).get("Error", {}).get("Code")
        status = getattr(error, "response", {}).get("ResponseMetadata", {}).get("HTTPStatusCode")
        if status == 412 or code in {"PreconditionFailed", "412"}:
            raise PublishError(f"conditional write conflict for {key}") from error
        raise
    finally:
        client.meta.events.unregister("before-sign.s3.PutObject", inject)
        handle = extra.get("Body")
        if hasattr(handle, "close") and handle is not sys.stdin:
            try:
                handle.close()
            except Exception:
                pass


def upload_prepared(
    prepared: PreparedRelease,
    *,
    client: Any,
    bucket: str,
    prefix: str = OBJECT_PREFIX,
    dry_run: bool = False,
    log: Callable[[str], None] = print,
) -> list[str]:
    uploads = [
        (object_key(prepared.identity, DMG_NAME, prefix), prepared.dmg_path, "application/x-apple-diskimage", prepared.sha256),
        (object_key(prepared.identity, "manifest.json", prefix), prepared.manifest_path, "application/json", file_sha256(prepared.manifest_path)),
        (object_key(prepared.identity, "appcast.xml", prefix), prepared.appcast_path, "application/xml", file_sha256(prepared.appcast_path)),
    ]
    for chunk_path in prepared.chunk_paths:
        uploads.append(
            (
                object_key(prepared.identity, f"chunks/{chunk_path.name}", prefix),
                chunk_path,
                "application/octet-stream",
                file_sha256(chunk_path),
            )
        )

    written: list[str] = []
    for key, path, content_type, digest in uploads:
        existing = None if dry_run else existing_object_sha256(client, bucket, key)
        if existing == digest:
            log(f"skip unchanged {key}")
            continue
        if existing:
            raise PublishError(f"refusing to overwrite {key} with different content")
        log(f"{'dry-run upload' if dry_run else 'upload'} {key}")
        if dry_run:
            written.append(key)
            continue
        put_object(
            client,
            bucket=bucket,
            key=key,
            body=path,
            content_type=content_type,
            sha256=digest,
            if_none_match="*",
        )
        written.append(key)
    return written


def download_and_hash(url: str, expected_size: int | None = None,
                      evidence: dict[str, Any] | None = None) -> tuple[int, str]:
    hasher = hashlib.sha256()
    size = 0
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"User-Agent": PUBLIC_USER_AGENT},
    )
    deadline = time.monotonic() + 900
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 200 or response.geturl() != url:
            raise PublishError("immutable download must return a direct 200")
        if expected_size is not None and response.headers.get("Content-Length") != str(expected_size):
            raise PublishError("download Content-Length does not match prepared size")
        if evidence is not None:
            evidence.update(response_evidence(response))
        while True:
            if time.monotonic() > deadline:
                raise PublishError("download exceeded the 15-minute verification deadline")
            block = response.read(1024 * 1024)
            if not block:
                break
            hasher.update(block)
            size += len(block)
            if expected_size is not None and size > expected_size:
                raise PublishError("downloaded file is larger than the prepared DMG")
    if expected_size is not None and size != expected_size:
        raise PublishError(f"downloaded size {size} does not match prepared size {expected_size}")
    return size, hasher.hexdigest()


def verify_prepared(prepared: PreparedRelease, *, origin: str = PUBLIC_ORIGIN,
                    log: Callable[[str], None] = print) -> dict[str, Any]:
    url = versioned_dmg_url(prepared.version, prepared.build, prepared.sha256, origin)
    log(f"verify {url}")
    evidence: dict[str, Any] = {}
    size, digest = download_and_hash(url, prepared.size, evidence)
    if digest != prepared.sha256:
        raise PublishError("downloaded SHA-256 does not match the prepared DMG")
    appcast_url = f"{origin.rstrip('/')}/downloads/voxstudio/appcast.xml"
    try:
        appcast_request = urllib.request.Request(
            appcast_url,
            method="GET",
            headers={"User-Agent": PUBLIC_USER_AGENT},
        )
        with urllib.request.urlopen(appcast_request, timeout=30) as response:
            current_appcast = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise PublishError(f"failed to read live appcast: HTTP {error.code}") from error
        current_appcast = ""
    if url not in Path(prepared.appcast_path).read_text():
        raise PublishError("prepared appcast enclosure is not the immutable version URL")
    log(f"verified size={size} sha256={digest} live_appcast_has_this_release={url in current_appcast}")
    if evidence.get("etag") != f'"{prepared.sha256}"':
        raise PublishError("download ETag does not match prepared SHA-256")
    log(json.dumps(evidence, sort_keys=True))
    return {**evidence, "size": size, "sha256": digest}


def promote_prepared(
    prepared: PreparedRelease,
    *,
    client: Any,
    bucket: str,
    prefix: str = OBJECT_PREFIX,
    dry_run: bool = False,
    log: Callable[[str], None] = print,
    expected_stable: dict[str, Any] | None = None,
) -> None:
    key = "/".join(part.strip("/") for part in (prefix, "channels/stable.json") if part)
    pointer = json.loads((prepared.staging_dir / "stable.json").read_text())
    body = (json.dumps(pointer, indent=2) + "\n").encode()
    digest = bytes_sha256(body)
    if dry_run:
        log(f"dry-run promote {key}")
        return
    if expected_stable is None:
        raise PublishError("promote requires the stable snapshot captured before verification")
    current = read_stable_snapshot(client, bucket, prefix)
    if current.get("identity") == prepared.identity:
        log(f"already promoted {prepared.identity}")
        return
    if current != expected_stable:
        raise PublishError("stable changed since verification; refusing to overwrite another release")
    condition = stable_write_condition(expected_stable.get("etag"))
    log(f"{'dry-run promote' if dry_run else 'promote'} {key} condition={condition}")
    put_object(
        client,
        bucket=bucket,
        key=key,
        body=body,
        content_type="application/json",
        sha256=digest,
        **condition,
    )


def fetch_live_appcast(origin: str = PUBLIC_ORIGIN) -> bytes | None:
    url = f"{origin.rstrip('/')}/downloads/voxstudio/appcast.xml"
    try:
        request = urllib.request.Request(
            url,
            method="GET",
            headers={"User-Agent": PUBLIC_USER_AGENT},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise PublishError(f"failed to read Cloudflare appcast: HTTP {error.code}") from error


def default_env_files(repo_root: Path) -> list[Path]:
    return [
        repo_root / ".env.prod",
        repo_root / ".env",
        repo_root.parent / "voxella-docker-deploy" / ".env.dev",
        repo_root.parent / "voxella-api" / ".env",
    ]


def load_runtime_environ(repo_root: Path, extra_files: list[Path]) -> dict[str, str]:
    environ = dict(os.environ)
    for path in [*extra_files, *default_env_files(repo_root)]:
        load_dotenv(path, environ)
    return environ


def response_evidence(response: Any) -> dict[str, Any]:
    headers = response.headers
    return {
        "url": response.geturl(), "status": response.status,
        "etag": headers.get("ETag"), "cf_ray": headers.get("CF-Ray"),
        "cache": headers.get("X-VoxStudio-Release-Cache"),
        "cache_version": headers.get("X-VoxStudio-Cache-Version"),
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


def read_stable_snapshot(client: Any, bucket: str, prefix: str = OBJECT_PREFIX) -> dict[str, Any]:
    key = f"{prefix.strip('/')}/channels/stable.json"
    try:
        response = client.get_object(Bucket=bucket, Key=key)
    except Exception as error:
        code = getattr(error, "response", {}).get("Error", {}).get("Code")
        if code in {"404", "NoSuchKey", "NotFound"}:
            return {"etag": None, "identity": None}
        raise
    body = response["Body"]
    try:
        pointer = json.loads(body.read())
    finally:
        body.close()
    return {"etag": response["ETag"].strip('"'),
            "identity": release_identity(pointer["version"], pointer["build"], pointer["sha256"])}


def cache_check_prepared(prepared: PreparedRelease, verification: Mapping[str, Any],
                         *, delivery_mode: str = "cache", attempts: int = 3) -> dict[str, Any]:
    if verification.get("sha256") != prepared.sha256 or verification.get("size") != prepared.size:
        raise PublishError("full integrity verification must succeed before cache-check")
    length = min(4096, prepared.size)
    if length <= 0:
        raise PublishError("empty DMG")
    with prepared.dmg_path.open("rb") as handle:
        expected = handle.read(length)
    request = urllib.request.Request(prepared.versioned_url, headers={
        "User-Agent": PUBLIC_USER_AGENT, "Range": f"bytes=0-{length - 1}",
        "If-Range": f'"{prepared.sha256}"',
    })
    last_cache = "UNKNOWN"
    for attempt in range(attempts):
        with urllib.request.urlopen(request, timeout=120) as response:
            evidence = response_evidence(response)
            if (response.status != 206 or response.geturl() != prepared.versioned_url
                    or response.headers.get("Content-Range") != f"bytes 0-{length - 1}/{prepared.size}"
                    or response.headers.get("Content-Length") != str(length)
                    or evidence["etag"] != f'"{prepared.sha256}"'
                    or response.read(length + 1) != expected):
                raise PublishError("cache-check range bytes or response headers failed integrity validation")
        last_cache = evidence["cache"] or "UNKNOWN"
        if delivery_mode == "origin":
            if last_cache != "ORIGIN":
                raise PublishError("origin release requires the public gateway to be in origin delivery mode")
            return evidence
        if evidence["cache_version"] != verification.get("cache_version") or not evidence["cache_version"]:
            raise PublishError("cache deployment changed or is unknown; repeat full verify")
        if last_cache == "HIT":
            return evidence
        if attempt + 1 < attempts:
            time.sleep(2)
    raise PublishError(f"cache-check never reached HIT (last={last_cache}); stable was not changed")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def postcheck_prepared(prepared: PreparedRelease) -> dict[str, Any]:
    request = urllib.request.Request(prepared.latest_url, method="HEAD", headers={"User-Agent": PUBLIC_USER_AGENT})
    try:
        response = urllib.request.build_opener(NoRedirect).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise PublishError(f"latest postcheck returned HTTP {error.code}") from error
        response = error
    with response:
        if (response.code != 302 or response.headers.get("Location") != prepared.versioned_url
                or "no-store" not in response.headers.get("Cache-Control", "")):
            raise PublishError("latest does not redirect without caching to the promoted release")
    payload = fetch_live_appcast(prepared.appcast_url.rsplit("/downloads/", 1)[0])
    if not payload:
        raise PublishError("appcast missing after promote")
    root = ET.fromstring(payload)
    enclosures = root.findall("./channel/item/enclosure")
    if not any(item.get("url") == prepared.versioned_url and item.get("length") == str(prepared.size)
               for item in enclosures):
        raise PublishError("live appcast does not contain the promoted immutable enclosure and size")
    return {"latest": prepared.latest_url, "versioned_url": prepared.versioned_url,
            "checked_at": datetime.now(timezone.utc).isoformat()}


def artifact_state(prepared: PreparedRelease) -> dict[str, Any]:
    state = load_state(prepared.staging_dir / "publish-state.json")
    identity = {"identity": prepared.identity, "versioned_url": prepared.versioned_url}
    if state and any(state.get(key) != value for key, value in identity.items()):
        raise PublishError("publish state belongs to another artifact or origin; use a separate staging directory")
    return state or {**identity, "completed": ["prepare"]}


def save_artifact_state(prepared: PreparedRelease, args: argparse.Namespace, state: dict[str, Any]) -> None:
    write_state(prepared.staging_dir / "publish-state.json", state)
    write_state(args.staging_root / "state.json", {**state, "staging_dir": str(prepared.staging_dir)})


def execute_publish_stages(prepared: PreparedRelease, args: argparse.Namespace, stages: list[str]) -> int:
    if any(stage not in STAGES for stage in stages):
        raise PublishError("unknown publication stage")
    if args.delivery_mode == "origin" and not args.origin_reason.strip():
        raise PublishError("origin delivery requires --origin-reason explaining the explicit downgrade")
    if args.delivery_mode == "cache" and prepared.size > MAX_CACHEABLE_BYTES:
        raise PublishError("DMG exceeds the cache size limit; an explicit origin downgrade is required")
    if args.dry_run:
        for stage in stages:
            print(f"dry-run {stage} {prepared.identity}")
        return 0  # Never save simulated verify/promote success.

    state = artifact_state(prepared)
    completed = set(state.get("completed", []))
    environ = load_runtime_environ(args.repo_root, args.env_file)
    settings = resolve_r2_settings(environ)
    target = {"bucket": settings["bucket"], "account_id": settings["account_id"], "prefix": OBJECT_PREFIX, "endpoint": settings["endpoint"]}
    if state.get("target") and state["target"] != target:
        raise PublishError("publish state targets another R2 environment")
    state.update(target=target, delivery_mode=args.delivery_mode, origin_reason=args.origin_reason)
    client = create_r2_client(settings)

    def done(stage: str, evidence: Any = None) -> None:
        completed.add(stage)
        state.update(stage=stage, completed=sorted(completed))
        if evidence is not None:
            state[stage] = evidence
        state.pop("last_error", None)
        save_artifact_state(prepared, args, state)

    for stage in stages:
        try:
            if stage in {"cache-check", "postcheck"}:
                completed.discard(stage)
            if stage == "upload":
                if stage not in completed:
                    upload_prepared(prepared, client=client, bucket=settings["bucket"])
                done(stage)
            elif stage == "verify":
                # A fresh verification establishes a fresh compare-and-swap baseline.
                snapshot = read_stable_snapshot(client, settings["bucket"])
                completed.difference_update({"verify", "cache-check", "postcheck"})
                state.update(expected_stable=snapshot, completed=sorted(completed))
                save_artifact_state(prepared, args, state)
                evidence = verify_prepared(prepared, origin=args.origin)
                done(stage, evidence)
            elif stage == "cache-check":
                if "verify" not in completed:
                    raise PublishError("verify must succeed for this artifact before cache-check")
                done(stage, cache_check_prepared(prepared, state["verify"], delivery_mode=args.delivery_mode))
            elif stage == "promote":
                current = read_stable_snapshot(client, settings["bucket"])
                if current.get("identity") == prepared.identity:
                    done(stage, {"already_current": True})
                    continue
                if not {"verify", "cache-check"}.issubset(completed):
                    raise PublishError("verify and cache-check must succeed for this artifact before promote")
                # Recheck the current cache deployment immediately before publishing.
                evidence = cache_check_prepared(prepared, state["verify"], delivery_mode=args.delivery_mode)
                done("cache-check", evidence)
                promote_prepared(prepared, client=client, bucket=settings["bucket"], expected_stable=state["expected_stable"])
                done(stage, {"already_current": False})
            elif stage == "postcheck":
                if "promote" not in completed:
                    raise PublishError("postcheck requires a recorded promote")
                done(stage, postcheck_prepared(prepared))
        except Exception as error:
            state.update(completed=sorted(completed), last_error={"stage": stage, "message": str(error)})
            save_artifact_state(prepared, args, state)
            prefix = "stable already switched; " if "promote" in completed else ""
            raise PublishError(f"{prefix}{stage} failed: {error}") from error
    print(json.dumps({"completed": sorted(completed), "identity": prepared.identity,
                      "versioned_url": prepared.versioned_url}, indent=2))
    return 0


def command_prepare(args: argparse.Namespace) -> int:
    if args.delivery_mode == "cache" and args.dmg.stat().st_size > MAX_CACHEABLE_BYTES:
        raise PublishError("DMG exceeds the cache size limit; use an explicit origin downgrade")
    prepared = prepare_release(
        dmg_path=args.dmg,
        staging_root=args.staging_root,
        version=args.version,
        build=str(args.build),
        signature=args.signature,
        arch=args.arch,
        minimum_system_version=args.minimum_system_version,
        origin=args.origin,
    )
    print(json.dumps({
        "identity": prepared.identity,
        "version": prepared.version,
        "build": prepared.build,
        "sha256": prepared.sha256,
        "size": prepared.size,
        "staging_dir": str(prepared.staging_dir),
        "versioned_url": prepared.versioned_url,
        "chunks": len(prepared.chunk_paths),
    }, indent=2))
    return 0


def command_upload(args: argparse.Namespace) -> int:
    return execute_publish_stages(load_prepared(args.staging_dir, args.origin), args, ["upload"])


def command_verify(args: argparse.Namespace) -> int:
    return execute_publish_stages(load_prepared(args.staging_dir, args.origin), args, ["verify"])


def command_cache_check(args: argparse.Namespace) -> int:
    return execute_publish_stages(load_prepared(args.staging_dir, args.origin), args, ["cache-check"])


def command_promote(args: argparse.Namespace) -> int:
    return execute_publish_stages(load_prepared(args.staging_dir, args.origin), args, ["promote", "postcheck"])


def command_postcheck(args: argparse.Namespace) -> int:
    return execute_publish_stages(load_prepared(args.staging_dir, args.origin), args, ["postcheck"])


def command_run(args: argparse.Namespace) -> int:
    requested = args.stages or list(STAGES)
    if args.skip_promote:
        requested = [stage for stage in requested if stage not in {"promote", "postcheck"}]
    if args.resume or "prepare" not in requested:
        staging_dir = args.staging_dir
        if staging_dir is None:
            state = load_state(args.staging_root / "state.json")
            if not state.get("staging_dir"):
                raise PublishError("nothing to resume; run prepare first")
            staging_dir = Path(state["staging_dir"])
        prepared = load_prepared(staging_dir, args.origin)
        if (prepared.version != args.version or prepared.build != str(args.build)
                or file_sha256(args.dmg) != prepared.sha256):
            raise PublishError("resume artifact does not match requested version/build/DMG")
        completed = set(artifact_state(prepared).get("completed", []))
        if args.resume:
            if "promote" in completed:
                requested = [stage for stage in requested if stage == "postcheck"]
            else:
                requested = [stage for stage in requested if stage not in completed or stage in {"cache-check", "promote", "postcheck"}]
    else:
        if args.delivery_mode == "cache" and args.dmg.stat().st_size > MAX_CACHEABLE_BYTES:
            raise PublishError("DMG exceeds the cache size limit; use an explicit origin downgrade")
        prepared = prepare_release(
            dmg_path=args.dmg, staging_root=args.staging_root, version=args.version,
            build=str(args.build), signature=args.signature, arch=args.arch,
            minimum_system_version=args.minimum_system_version, origin=args.origin,
        )
        print(f"prepared {prepared.identity} size={prepared.size} sha256={prepared.sha256}")
    return execute_publish_stages(prepared, args, [stage for stage in STAGES if stage in requested and stage != "prepare"])


def command_resume(args: argparse.Namespace) -> int:
    staging_dir = args.staging_dir or load_state(args.staging_root / "state.json").get("staging_dir")
    if not staging_dir:
        raise PublishError("nothing to resume; run prepare first")
    prepared = load_prepared(Path(staging_dir), args.origin)
    args.staging_dir = prepared.staging_dir
    args.dmg, args.version, args.build = prepared.dmg_path, prepared.version, prepared.build
    args.resume, args.stages = True, None
    return command_run(args)


def command_fetch_appcast(args: argparse.Namespace) -> int:
    payload = fetch_live_appcast(args.origin)
    if payload is None:
        print("Cloudflare appcast is not published yet", file=sys.stderr)
        return 2
    args.output.write_bytes(payload)
    return 0


def add_shared_arguments(parser: argparse.ArgumentParser, repo_root: Path) -> None:
    parser.add_argument("--repo-root", type=Path, default=repo_root)
    parser.add_argument("--staging-root", type=Path, default=repo_root / ".build" / "r2-release")
    parser.add_argument("--origin", default=PUBLIC_ORIGIN)
    parser.add_argument("--env-file", action="append", default=[], type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--delivery-mode", choices=["cache", "origin"], default="cache")
    parser.add_argument("--origin-reason", default="")


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Publish a VoxStudio DMG to Cloudflare R2")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare")
    add_shared_arguments(prepare_parser, repo_root)
    prepare_parser.add_argument("--dmg", type=Path, required=True)
    prepare_parser.add_argument("--version", required=True)
    prepare_parser.add_argument("--build", required=True)
    prepare_parser.add_argument("--signature", required=True)
    prepare_parser.add_argument("--arch", default=DEFAULT_ARCH)
    prepare_parser.add_argument("--minimum-system-version", default=DEFAULT_MINIMUM_SYSTEM_VERSION)

    upload_parser = subparsers.add_parser("upload")
    add_shared_arguments(upload_parser, repo_root)
    upload_parser.add_argument("--staging-dir", type=Path, required=True)

    verify_parser = subparsers.add_parser("verify")
    add_shared_arguments(verify_parser, repo_root)
    verify_parser.add_argument("--staging-dir", type=Path, required=True)

    promote_parser = subparsers.add_parser("promote")
    add_shared_arguments(promote_parser, repo_root)
    promote_parser.add_argument("--staging-dir", type=Path, required=True)
    for name in ("cache-check", "postcheck"):
        stage_parser = subparsers.add_parser(name)
        add_shared_arguments(stage_parser, repo_root)
        stage_parser.add_argument("--staging-dir", type=Path, required=True)

    run_parser = subparsers.add_parser("run")
    add_shared_arguments(run_parser, repo_root)
    run_parser.add_argument("--dmg", type=Path, required=True)
    run_parser.add_argument("--version", required=True)
    run_parser.add_argument("--build", required=True)
    run_parser.add_argument("--signature", required=True)
    run_parser.add_argument("--arch", default=DEFAULT_ARCH)
    run_parser.add_argument("--minimum-system-version", default=DEFAULT_MINIMUM_SYSTEM_VERSION)
    run_parser.add_argument("--staging-dir", type=Path)
    run_parser.add_argument("--stages", nargs="+", choices=STAGES)
    run_parser.add_argument("--resume", action="store_true")
    run_parser.add_argument("--skip-promote", action="store_true")

    resume_parser = subparsers.add_parser("resume")
    add_shared_arguments(resume_parser, repo_root)
    resume_parser.add_argument("--staging-dir", type=Path)
    resume_parser.add_argument("--skip-promote", action="store_true")

    fetch_parser = subparsers.add_parser("fetch-appcast")
    add_shared_arguments(fetch_parser, repo_root)
    fetch_parser.add_argument("--output", type=Path, required=True)

    args = parser.parse_args()
    commands = {
        "prepare": command_prepare,
        "upload": command_upload,
        "verify": command_verify,
        "promote": command_promote,
        "cache-check": command_cache_check,
        "postcheck": command_postcheck,
        "run": command_run,
        "resume": command_resume,
        "fetch-appcast": command_fetch_appcast,
    }
    try:
        return commands[args.command](args)
    except PublishError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
