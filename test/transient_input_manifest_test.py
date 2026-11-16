from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import unittest
from transient_input_manifest import digest, paths

class RuntimeInputControls(unittest.TestCase):
    def setUp(self):
        self.scratch=TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root=Path(self.scratch.name)
        self.binary=self.root/'.build/debug/Pathem'
        for name,content in {
            '.build/debug/Pathem':b'binary',
            '.build/debug/Pathem_Pathem.bundle/CHANGELOG.md':b'bundled changelog',
            '.build/debug/Sparkle.framework/Versions/B/Sparkle':b'framework',
            'Sources/Pathem/Resources/fixture.json':b'fixture',
            'Sources/PathemEngine/Fixture.swift':b'engine',
            'test/transient_fixture.json':b'{}',
            'Package.swift':b'package',
        }.items():
            p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(content)
        self.tool=patch('transient_input_manifest.subprocess.check_output',return_value='binary:\n\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0)\n\t/System/Library/Frameworks/AppKit.framework/AppKit (compatibility version 1.0)\n')
        self.tool.start();self.addCleanup(self.tool.stop)
    def test_unchanged_inputs_stable(self):self.assertEqual(digest(self.root),digest(self.root))
    def test_bundled_non_catalog_resource_is_bound(self):
        before=digest(self.root);(self.root/'.build/debug/Pathem_Pathem.bundle/CHANGELOG.md').write_text('changed')
        self.assertNotEqual(before,digest(self.root))
    def test_linked_framework_is_bound(self):
        before=digest(self.root);(self.root/'.build/debug/Sparkle.framework/Versions/B/Sparkle').write_text('changed')
        self.assertNotEqual(before,digest(self.root))
    def test_engine_source_is_bound(self):
        before=digest(self.root);(self.root/'Sources/PathemEngine/Fixture.swift').write_text('changed')
        self.assertNotEqual(before,digest(self.root))
    def test_receipt_output_does_not_change_inputs(self):
        before=digest(self.root);(self.root/'.build/run.log').write_text('receipt')
        self.assertEqual(before,digest(self.root))
    def test_unknown_dependency_refused(self):
        with patch('transient_input_manifest.subprocess.check_output',return_value='binary:\n /unexpected/Library.dylib (compatibility version 1)\n'):
            with self.assertRaisesRegex(ValueError,'Unclassified'):paths(self.root)
    def test_missing_dependency_refused(self):
        import shutil
        shutil.rmtree(self.root/'.build/debug/Sparkle.framework')
        with self.assertRaisesRegex(ValueError,'Missing linked'):paths(self.root)
    def test_framework_directory_without_linked_binary_refused(self):
        (self.root/'.build/debug/Sparkle.framework/Versions/B/Sparkle').unlink()
        with self.assertRaisesRegex(ValueError,'Missing linked'):paths(self.root)

    def test_runtime_isolation_helper_is_bound(self):
        helper=self.root/'test/layout_matrix_support.py'
        helper.write_text('def verify_defaults(): return True')
        before=digest(self.root)
        helper.write_text('def verify_defaults(): return False')
        self.assertNotEqual(before,digest(self.root))
