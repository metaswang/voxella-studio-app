import importlib.util
import json
import sys
import tempfile
import unittest
import io
from contextlib import contextmanager
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "r2_release.py"
SPEC = importlib.util.spec_from_file_location("r2_release", MODULE_PATH)
r2_release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["r2_release"] = r2_release
SPEC.loader.exec_module(r2_release)


class R2ReleaseTests(unittest.TestCase):
    @contextmanager
    def artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "VoxStudio.dmg"
            dmg.write_bytes(b"0123456789abcdefghij")
            prepared = r2_release.prepare_release(dmg_path=dmg, staging_root=root / "staging",
                version="7.0.16", build="97", signature="test-signature")
            args = SimpleNamespace(staging_root=root / "staging", repo_root=root,
                env_file=[], origin=r2_release.PUBLIC_ORIGIN, delivery_mode="cache", origin_reason="",
                dry_run=False, resume=True, stages=None, skip_promote=False,
                staging_dir=prepared.staging_dir, dmg=prepared.dmg_path, version=prepared.version, build=prepared.build)
            yield prepared, args

    def verification(self, prepared):
        return {"sha256": prepared.sha256, "size": prepared.size, "cache_version": "deployment-1"}

    def response(self, prepared, *, cache="HIT", version="deployment-1", body=None, status=206):
        payload = prepared.dmg_path.read_bytes() if body is None else body
        response = io.BytesIO(payload)
        response.status = response.code = status
        response.geturl = lambda: prepared.versioned_url
        response.headers = {"Content-Length": str(prepared.size), "ETag": f'"{prepared.sha256}"',
            "Content-Range": f"bytes 0-{prepared.size - 1}/{prepared.size}",
            "X-VoxStudio-Release-Cache": cache, "X-VoxStudio-Cache-Version": version}
        return response

    def runtime(self):
        return patch.multiple(r2_release,
            load_runtime_environ=lambda *_: {},
            resolve_r2_settings=lambda _: {"bucket": "vox", "account_id": "test", "endpoint": "https://r2.invalid"},
            create_r2_client=lambda _: object())

    def test_cache_check_requires_hit_and_exact_bytes(self):
        with self.artifact() as (prepared, _):
            with patch.object(r2_release.urllib.request, "urlopen", return_value=self.response(prepared)):
                self.assertEqual(r2_release.cache_check_prepared(prepared, self.verification(prepared))["cache"], "HIT")
            with patch.object(r2_release.urllib.request, "urlopen", return_value=self.response(prepared, body=b"wrong")):
                with self.assertRaisesRegex(r2_release.PublishError, "integrity"):
                    r2_release.cache_check_prepared(prepared, self.verification(prepared))

    def test_dynamic_never_passes_and_retries_are_bounded(self):
        with self.artifact() as (prepared, _):
            with patch.object(r2_release.urllib.request, "urlopen", side_effect=lambda *_args, **_kw: self.response(prepared, cache="DYNAMIC")) as request, patch.object(r2_release.time, "sleep"):
                with self.assertRaisesRegex(r2_release.PublishError, "never reached HIT"):
                    r2_release.cache_check_prepared(prepared, self.verification(prepared))
                self.assertEqual(request.call_count, 3)

    def test_cache_deployment_change_requires_full_verification(self):
        with self.artifact() as (prepared, _):
            with patch.object(r2_release.urllib.request, "urlopen", return_value=self.response(prepared, version="deployment-2")):
                with self.assertRaisesRegex(r2_release.PublishError, "deployment changed"):
                    r2_release.cache_check_prepared(prepared, self.verification(prepared))

    def test_origin_downgrade_checks_actual_gateway_mode(self):
        with self.artifact() as (prepared, _):
            with patch.object(r2_release.urllib.request, "urlopen", return_value=self.response(prepared, cache="FALLBACK")):
                with self.assertRaisesRegex(r2_release.PublishError, "origin delivery"):
                    r2_release.cache_check_prepared(prepared, self.verification(prepared), delivery_mode="origin")

    def test_promote_rejects_stable_change_and_preserves_cas(self):
        with self.artifact() as (prepared, _):
            expected = {"etag": "before", "identity": "older"}
            with patch.object(r2_release, "read_stable_snapshot", return_value={"etag": "after", "identity": "another"}), patch.object(r2_release, "put_object") as put:
                with self.assertRaisesRegex(r2_release.PublishError, "stable changed"):
                    r2_release.promote_prepared(prepared, client=object(), bucket="vox", expected_stable=expected)
                put.assert_not_called()
            with patch.object(r2_release, "read_stable_snapshot", return_value=expected), patch.object(r2_release, "put_object") as put:
                r2_release.promote_prepared(prepared, client=object(), bucket="vox", expected_stable=expected)
                self.assertEqual(put.call_args.kwargs["if_match"], "before")

    def test_repeat_promote_does_not_write_again(self):
        with self.artifact() as (prepared, _):
            with patch.object(r2_release, "read_stable_snapshot", return_value={"etag": "now", "identity": prepared.identity}), patch.object(r2_release, "put_object") as put:
                r2_release.promote_prepared(prepared, client=object(), bucket="vox", expected_stable={"etag": "old"})
                put.assert_not_called()

    def test_dry_run_never_records_verification_or_publication(self):
        with self.artifact() as (prepared, args):
            args.dry_run = True
            with patch.object(r2_release, "create_r2_client") as client:
                r2_release.execute_publish_stages(prepared, args, ["verify", "cache-check", "promote", "postcheck"])
                client.assert_not_called()
            self.assertFalse((prepared.staging_dir / "publish-state.json").exists())
            self.assertEqual(r2_release.load_state(args.staging_root / "state.json")["completed"], ["prepare"])

    def test_root_state_cannot_authorize_another_artifact(self):
        with self.artifact() as (prepared, args):
            r2_release.write_state(args.staging_root / "state.json", {"completed": ["verify", "cache-check"], "identity": "other"})
            with self.runtime(), patch.object(r2_release, "read_stable_snapshot", return_value={"identity": "older"}), patch.object(r2_release, "promote_prepared") as promote:
                with self.assertRaisesRegex(r2_release.PublishError, "verify and cache-check"):
                    r2_release.execute_publish_stages(prepared, args, ["promote"])
                promote.assert_not_called()

    def test_origin_state_cannot_be_reused_for_another_origin(self):
        with self.artifact() as (prepared, _):
            r2_release.write_state(prepared.staging_dir / "publish-state.json", {
                "identity": prepared.identity, "versioned_url": "https://other.invalid/file"})
            with self.assertRaisesRegex(r2_release.PublishError, "another artifact or origin"):
                r2_release.artifact_state(prepared)

    def test_postcheck_failure_preserves_successful_promote(self):
        with self.artifact() as (prepared, args):
            state = {"identity": prepared.identity, "versioned_url": prepared.versioned_url,
                "completed": ["verify", "cache-check"], "verify": self.verification(prepared),
                "expected_stable": {"etag": "old", "identity": "older"}}
            r2_release.save_artifact_state(prepared, args, state)
            with self.runtime(), patch.object(r2_release, "read_stable_snapshot", return_value={"identity": "older"}), patch.object(r2_release, "cache_check_prepared", return_value={"cache": "HIT"}), patch.object(r2_release, "promote_prepared"), patch.object(r2_release, "postcheck_prepared", side_effect=RuntimeError("network unavailable")):
                with self.assertRaisesRegex(r2_release.PublishError, "stable already switched"):
                    r2_release.execute_publish_stages(prepared, args, ["promote", "postcheck"])
            saved = r2_release.artifact_state(prepared)
            self.assertIn("promote", saved["completed"])
            self.assertNotIn("postcheck", saved["completed"])
            with patch.object(r2_release, "execute_publish_stages", return_value=0) as execute:
                r2_release.command_run(args)
                self.assertEqual(execute.call_args.args[2], ["postcheck"])

    def test_verify_failure_invalidates_old_success(self):
        with self.artifact() as (prepared, args):
            r2_release.save_artifact_state(prepared, args, {"identity": prepared.identity,
                "versioned_url": prepared.versioned_url, "completed": ["verify", "cache-check"]})
            with self.runtime(), patch.object(r2_release, "read_stable_snapshot", return_value={"etag": "old", "identity": "older"}), patch.object(r2_release, "verify_prepared", side_effect=r2_release.PublishError("bad SHA")):
                with self.assertRaisesRegex(r2_release.PublishError, "bad SHA"):
                    r2_release.execute_publish_stages(prepared, args, ["verify"])
            self.assertNotIn("verify", r2_release.artifact_state(prepared)["completed"])

    def test_full_download_detects_truncation(self):
        with self.artifact() as (prepared, _):
            with patch.object(r2_release.urllib.request, "urlopen", return_value=self.response(prepared, body=b"short", status=200)):
                with self.assertRaisesRegex(r2_release.PublishError, "downloaded size"):
                    r2_release.download_and_hash(prepared.versioned_url, prepared.size)

    def test_splits_files_into_fixed_chunks_and_a_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "VoxStudio.dmg"
            dmg.write_bytes(b"abcdefghijklmnopqrstuvwxyz012345")
            chunks = r2_release.split_chunks(dmg, chunk_size=8)
            self.assertEqual([chunk.length for chunk in chunks], [8, 8, 8, 8])
            self.assertEqual(chunks[0].offset, 0)
            self.assertEqual(chunks[-1].offset, 24)

    def test_prepare_writes_immutable_appcast_enclosure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "VoxStudio.dmg"
            payload = b"0123456789abcdefghij"
            dmg.write_bytes(payload)
            prepared = r2_release.prepare_release(
                dmg_path=dmg,
                staging_root=root / "staging",
                version="7.0.16",
                build="97",
                signature="test-signature",
            )
            self.assertEqual(prepared.size, len(payload))
            self.assertEqual(prepared.sha256, r2_release.file_sha256(dmg))
            self.assertIn(prepared.sha256, prepared.versioned_url)
            self.assertTrue(prepared.versioned_url.endswith("/VoxStudio.dmg"))
            self.assertNotIn("/downloads/voxstudio/VoxStudio.dmg", Path(prepared.appcast_path).read_text().split("url=")[1])
            self.assertIn(prepared.versioned_url, prepared.appcast_path.read_text())
            manifest = json.loads(prepared.manifest_path.read_text())
            self.assertEqual(manifest["chunkSize"], r2_release.CHUNK_SIZE_BYTES)
            self.assertEqual(sum(chunk["length"] for chunk in manifest["chunks"]), len(payload))

    def test_delta_url_uses_public_downloads_path(self):
        url = r2_release.versioned_delta_url(
            "7.0.25", "106", "abc123", "105-to-106.delta", "https://updates.example"
        )
        self.assertEqual(
            url,
            "https://updates.example/downloads/voxstudio/releases/7.0.25-106/abc123/deltas/105-to-106.delta",
        )

    def test_merge_deltas_keeps_full_dmg_fallback_and_delta_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "VoxStudio.dmg"
            dmg.write_bytes(b"full-update")
            manifest = r2_release.build_manifest(
                version="7.0.25", build="106", dmg_path=dmg, signature="full-signature"
            )
            base_appcast = r2_release.build_appcast(
                manifest, origin="https://updates.example"
            )
            delta = r2_release.DeltaArtifact(
                from_version="7.0.24",
                from_build="105",
                to_version="7.0.25",
                to_build="106",
                local_path=Path(directory) / "105-to-106.delta",
                size=1234,
                sha256="delta-sha256",
                signature="delta-signature",
            )

            merged = r2_release.merge_deltas_into_appcast(
                base_appcast,
                [delta],
                "7.0.25",
                "106",
                manifest.sha256,
                "https://updates.example",
            )
            root = r2_release.ET.fromstring(merged)
            ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
            item = root.find("channel/item")
            self.assertIsNotNone(item)
            full = item.find("enclosure")
            self.assertEqual(
                full.get("url"),
                r2_release.versioned_dmg_url(
                    "7.0.25", "106", manifest.sha256, "https://updates.example"
                ),
            )
            self.assertEqual(full.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"), "full-signature")

            deltas = item.find("sparkle:deltas", ns)
            self.assertIsNotNone(deltas)
            patch = deltas.find("enclosure")
            self.assertEqual(patch.get("url"), delta.versioned_url("7.0.25", "106", manifest.sha256, "https://updates.example"))
            self.assertEqual(patch.get("length"), "1234")
            self.assertEqual(patch.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"), "delta-signature")
            self.assertEqual(patch.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}deltaFrom"), "105")

    def test_refuses_to_overwrite_a_different_object(self):
        class FakeClient:
            def __init__(self) -> None:
                self.objects = {"app-releases/voxstudio/releases/7.0.16-97/abc/VoxStudio.dmg": "old"}

            def head_object(self, Bucket, Key):  # noqa: N803
                if Key not in self.objects:
                    error = Exception("missing")
                    error.response = {"Error": {"Code": "404"}}
                    raise error
                return {"Metadata": {"sha256": self.objects[Key]}}

        self.assertEqual(r2_release.existing_object_sha256(FakeClient(), "vox", "missing"), None)
        self.assertEqual(
            r2_release.existing_object_sha256(
                FakeClient(),
                "vox",
                "app-releases/voxstudio/releases/7.0.16-97/abc/VoxStudio.dmg",
            ),
            "old",
        )

    def test_stable_promote_uses_create_or_replace_conditions(self):
        self.assertEqual(r2_release.stable_write_condition(None), {"if_none_match": "*"})
        self.assertEqual(r2_release.stable_write_condition("etag-1"), {"if_match": "etag-1"})


if __name__ == "__main__":
    unittest.main()
