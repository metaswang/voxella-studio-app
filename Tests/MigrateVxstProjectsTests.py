import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "migrate-vxst-projects.py"
SPEC = importlib.util.spec_from_file_location("migrate_vxst_projects", MODULE_PATH)
migrate_vxst = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(migrate_vxst)

TIMELINE = {"timelines": [{"id": "T1", "tracks": []}], "activeTimelineId": "T1", "openTimelineIds": ["T1"]}
LIBRARY = {"version": 2, "entries": [], "folders": []}
GENERATIONS = {"version": 1, "entries": []}


def make_legacy(root: Path, name="Demo.voxella", version="1"):
    package = root / name
    (package / "media").mkdir(parents=True)
    (package / "chat").mkdir()
    (package / "format.vxst").write_text(f"voxstudio.project\n{version}")
    (package / "timeline.vxst").write_text(json.dumps(TIMELINE))
    (package / "library.vxst").write_text(json.dumps(LIBRARY))
    (package / "generations.vxst").write_text(json.dumps(GENERATIONS))
    (package / "thumbnail.jpg").write_bytes(b"jpg")
    return package


class MigrateVxstProjectsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "projects"
        self.root.mkdir()
        self.backups = Path(self.temp.name) / "backups"

    def tearDown(self):
        self.temp.cleanup()

    def test_dry_run_reports_without_changing_files(self):
        package = make_legacy(self.root)
        results = migrate_vxst.migrate([self.root], backup_root=self.backups, stamp="t")
        self.assertEqual([item["status"] for item in results], ["pending"])
        self.assertTrue((package / "timeline.vxst").exists())
        self.assertFalse((package / "project.json").exists())
        self.assertFalse(self.backups.exists())

    def test_apply_renames_documents_and_keeps_backup(self):
        package = make_legacy(self.root)
        results = migrate_vxst.migrate([self.root], apply=True, backup_root=self.backups, stamp="t")
        self.assertEqual(results[0]["status"], "converted")
        self.assertEqual(json.loads((package / "project.json").read_text()), TIMELINE)
        self.assertEqual(json.loads((package / "media.json").read_text()), LIBRARY)
        self.assertEqual(json.loads((package / "generation-log.json").read_text()), GENERATIONS)
        self.assertEqual(sorted(p.name for p in package.iterdir()),
                         ["chat", "generation-log.json", "media", "media.json", "project.json", "thumbnail.jpg"])
        self.assertTrue((self.backups / "vxst-migration-t" / "Demo.voxella" / "timeline.vxst").exists())

    def test_current_packages_are_left_alone(self):
        package = self.root / "Current.voxella"
        package.mkdir()
        (package / "project.json").write_text(json.dumps(TIMELINE))
        self.assertEqual(migrate_vxst.migrate([self.root], apply=True, backup_root=self.backups, stamp="t"), [])

    def test_conflicts_and_unknown_versions_are_reported_not_changed(self):
        conflict = make_legacy(self.root, "Conflict.voxella")
        (conflict / "project.json").write_text("{}")
        make_legacy(self.root, "Future.voxella", version="9")
        results = migrate_vxst.migrate([self.root], apply=True, backup_root=self.backups, stamp="t")
        self.assertEqual([item["status"] for item in results], ["error", "error"])
        self.assertTrue((conflict / "timeline.vxst").exists())
        self.assertEqual((conflict / "project.json").read_text(), "{}")

    def test_invalid_json_fails_before_any_write(self):
        package = make_legacy(self.root)
        (package / "library.vxst").write_text("{broken")
        results = migrate_vxst.migrate([self.root], apply=True, backup_root=self.backups, stamp="t")
        self.assertEqual(results[0]["status"], "error")
        self.assertFalse((package / "project.json").exists())

    def test_import_to_sandbox_copies_package_and_repoints_registry(self):
        package = self.root / "Outside.voxella"
        package.mkdir()
        (package / "project.json").write_text(json.dumps(TIMELINE))
        documents = Path(self.temp.name) / "container" / "VoxStudio"
        documents.mkdir(parents=True)
        (documents / "project-registry.json").write_text(json.dumps(
            [{"id": "ID1", "url": migrate_vxst.file_url(package), "createdDate": 1, "lastOpenedDate": 2}]))
        results = migrate_vxst.import_to_sandbox([package], documents)
        self.assertEqual([item["status"] for item in results], ["imported"])
        self.assertTrue((documents / "Outside.voxella" / "project.json").exists())
        registry = json.loads((documents / "project-registry.json").read_text())
        self.assertEqual(registry, [{"id": "ID1", "url": migrate_vxst.file_url(documents / "Outside.voxella"),
                                     "createdDate": 1, "lastOpenedDate": 2}])
        again = migrate_vxst.import_to_sandbox([package], documents)
        self.assertEqual(again[0]["status"], "error")


if __name__ == "__main__":
    unittest.main()
