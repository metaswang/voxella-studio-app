import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "release_version.py"
SPEC = importlib.util.spec_from_file_location("release_version", MODULE_PATH)
release_version = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release_version)


class ReleaseVersionTests(unittest.TestCase):
    def test_accepts_three_numeric_components(self):
        self.assertEqual(
            release_version.ReleaseVersion.parse("7.0.6"),
            release_version.ReleaseVersion(7, 0, 6),
        )

    def test_rejects_noncanonical_versions(self):
        for value in ("7.0", "v7.0.6", "7.0.6-beta", "07.0.6"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release_version.ReleaseVersion.parse(value)

    def test_reuses_current_unpublished_build(self):
        build = release_version.planned_build(
            requested=release_version.ReleaseVersion.parse("7.0.6"),
            current=release_version.ReleaseVersion.parse("7.0.6"),
            current_build=86,
            published=release_version.PublishedRelease(
                release_version.ReleaseVersion.parse("0.8.1"), 85
            ),
        )
        self.assertEqual(build, 86)

    def test_increments_highest_build_for_new_version(self):
        build = release_version.planned_build(
            requested=release_version.ReleaseVersion.parse("7.0.7"),
            current=release_version.ReleaseVersion.parse("7.0.6"),
            current_build=86,
            published=release_version.PublishedRelease(
                release_version.ReleaseVersion.parse("7.0.6"), 90
            ),
        )
        self.assertEqual(build, 91)

    def test_rejects_version_regression(self):
        with self.assertRaises(ValueError):
            release_version.planned_build(
                requested=release_version.ReleaseVersion.parse("7.0.5"),
                current=release_version.ReleaseVersion.parse("7.0.6"),
                current_build=86,
                published=release_version.PublishedRelease(
                    release_version.ReleaseVersion.parse("0.8.1"), 85
                ),
            )

    def test_auto_increments_patch_after_latest_published_version(self):
        next_version = release_version.next_patch_version(
            current=release_version.ReleaseVersion.parse("7.0.7"),
            published=release_version.PublishedRelease(
                release_version.ReleaseVersion.parse("7.0.7"), 91
            ),
        )
        self.assertEqual(next_version, release_version.ReleaseVersion.parse("7.0.8"))

    def test_auto_increments_from_newer_current_version(self):
        next_version = release_version.next_patch_version(
            current=release_version.ReleaseVersion.parse("7.0.9"),
            published=release_version.PublishedRelease(
                release_version.ReleaseVersion.parse("7.0.7"), 91
            ),
        )
        self.assertEqual(next_version, release_version.ReleaseVersion.parse("7.0.10"))

    def test_reads_version_and_build_independently(self):
        appcast = """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item><sparkle:version>91</sparkle:version><sparkle:shortVersionString>7.0.6</sparkle:shortVersionString></item>
    <item><sparkle:version>90</sparkle:version><sparkle:shortVersionString>7.0.7</sparkle:shortVersionString></item>
  </channel>
</rss>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(appcast)
            published = release_version.latest_published_release(path)
            result = subprocess.run(
                [sys.executable, str(MODULE_PATH), "next", "--current", "7.0.7", "--appcast", str(path)],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(result.stdout.strip(), "7.0.8")
        self.assertEqual(published.build, 91)
        self.assertEqual(published.version, release_version.ReleaseVersion.parse("7.0.7"))


if __name__ == "__main__":
    unittest.main()
