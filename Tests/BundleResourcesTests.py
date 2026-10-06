"""Resource layout regressions for native SwiftPM and the Swift Build engine."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import patch_swiftpm_bundle_accessors as accessors
from bundle_resources import bundle_resource_directory, resource_path
import build_metal as metal
import verify_metal as verify


class BundleResourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def source(self, relative, contents):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def test_native_accessors_are_discovered(self):
        path = self.source('release/Target.build/DerivedSources/resource_bundle_accessor.swift', 'test')
        self.assertEqual(accessors.find_accessors(self.root / 'release'), [path])

    def test_swiftbuild_discovery_is_limited_to_requested_configuration(self):
        release = self.source('out/Intermediates.noindex/Package.build/Release/Target.build/DerivedSources/resource_bundle_accessor.swift', 'test')
        self.source('out/Intermediates.noindex/Package.build/Debug/Target.build/DerivedSources/resource_bundle_accessor.swift', 'test')
        self.source('out/Intermediates.noindex/Package.build/Release/Target.build/DerivedSources/resource_bundle_accessor.h', 'test')
        self.assertEqual(accessors.find_accessors(self.root / 'out/Products/Release'), [release])

    def test_legacy_lookup_is_repaired_idempotently(self):
        path = self.source('accessor.swift', 'let path = Bundle.main.bundleURL.appendingPathComponent("Package_Target.bundle").path')
        self.assertTrue(accessors.patch_accessor(path, {'Package_Target'}))
        self.assertIn('"Contents/Resources"', path.read_text())
        self.assertFalse(accessors.patch_accessor(path, {'Package_Target'}))

    def test_modern_lookup_is_retained_without_rewriting(self):
        source = 'let bundleName = "Package_Target"\nlet candidates = [Bundle.main.resourceURL]'
        path = self.source('accessor.swift', source)
        self.assertFalse(accessors.patch_accessor(path, {'Package_Target'}))
        self.assertEqual(path.read_text(), source)

    def test_swift_and_objc_generated_names_match_actual_bundle_names(self):
        for suffix, source in (
            ('swift', 'let bundleName = "some_package_Target"\nlet candidates = [Bundle.main.resourceURL]'),
            ('m', 'NSString *bundleName = @"some_package_Target";\nNSArray *candidates = @[[NSBundle mainBundle] resourceURL];'),
            ('m', 'NSString *bundleName = @"some_package_Target";\nNSArray *candidates = @[NSBundle.mainBundle.resourceURL];'),
        ):
            path = self.source(f'accessor.{suffix}', source)
            self.assertTrue(accessors.patch_accessor(path, {'some-package_Target'}))
            self.assertIn('"some-package_Target"', path.read_text())
            self.assertFalse(accessors.patch_accessor(path, {'some-package_Target'}))

    def test_ambiguous_generated_name_fails_without_modifying_source(self):
        source = 'let bundleName = "some_package_Target"\nlet candidates = [Bundle.main.resourceURL]'
        path = self.source('accessor.swift', source)
        with self.assertRaisesRegex(ValueError, 'Cannot resolve'):
            accessors.patch_accessor(path, {'some-package_Target', 'some.package_Target'})
        self.assertEqual(path.read_text(), source)

    def test_unknown_lookup_fails_instead_of_claiming_compatibility(self):
        path = self.source('accessor.swift', 'fatalError("no bundle")')
        with self.assertRaisesRegex(ValueError, 'Unrecognized'):
            accessors.patch_accessor(path, set())

    def test_flat_and_structured_bundle_resource_resolution(self):
        bundle = self.root / 'Package_Target.bundle'
        bundle.mkdir()
        self.assertEqual(bundle_resource_directory(bundle), bundle)
        structured = bundle / 'Contents/Resources'
        structured.mkdir(parents=True)
        self.assertEqual(bundle_resource_directory(bundle), structured)
        self.assertEqual(resource_path(self.root, 'Package_Target.bundle/default.metallib'), structured / 'default.metallib')

    def manifest(self, structured):
        bundle = self.root / 'mlx-swift_Cmlx.bundle'
        folder = bundle / 'Contents/Resources' if structured else bundle
        folder.mkdir(parents=True)
        shader = folder / 'default.metallib'
        shader.write_bytes(b'shader')
        (self.root / 'metal-build.json').write_text('manifest fixture')
        entries = [{
            'path': 'mlx-swift_Cmlx.bundle/default.metallib', 'bytes': 6, 'sha256': metal.sha(shader),
        }]
        for source in (ROOT / 'Metal').glob('*.metal'):
            library = self.root / f'{source.stem}.metallib'
            library.write_bytes(b'shader')
            entries.append({'path': library.name, 'bytes': 6, 'sha256': metal.sha(library)})
        manifest = {'schema': 1, **metal.policy(), 'libraries': entries}
        return manifest

    def test_structured_shader_verification_keeps_canonical_manifest_paths(self):
        manifest = self.manifest(True)
        with patch.object(verify.json, 'loads', return_value=manifest):
            self.assertEqual(verify.verify_resources(self.root, '15.0'), manifest)

    def test_duplicate_flat_shader_beside_structured_shader_is_rejected(self):
        manifest = self.manifest(True)
        (self.root / 'mlx-swift_Cmlx.bundle/default.metallib').write_bytes(b'shader')
        with patch.object(verify.json, 'loads', return_value=manifest):
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                verify.verify_resources(self.root, '15.0')

    def test_structured_module_shader_mismatch_is_rejected(self):
        manifest = self.manifest(False)
        self.source('VoxstudioPro_VoxstudioPro.bundle/Contents/Resources/default.metallib', 'damaged')
        with patch.object(verify.json, 'loads', return_value=manifest):
            with self.assertRaisesRegex(ValueError, 'differs'):
                verify.verify_resources(self.root, '15.0')


if __name__ == '__main__':
    unittest.main()
