import pathlib
import plistlib
import tempfile
import unittest
import subprocess
from types import SimpleNamespace
from transient_app_bundle import dependency_paths, prepare_bundle, clear_private_domain

class PrivateBundleTests(unittest.TestCase):
    def fixture(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        root=pathlib.Path(temp.name);source=root/'build/Pathem';source.parent.mkdir();source.write_bytes(b'owned executable');scratch=root/'run';scratch.mkdir()
        resource=source.parent/'Pathem_Pathem.bundle/de.lproj';resource.mkdir(parents=True);(resource/'Localizable.strings').write_text('owned translation')
        return root,source,scratch

    def test_framework_is_copied_and_preflighted(self):
        root,source,scratch=self.fixture()
        library=source.parent/'Sparkle.framework/Versions/B/Sparkle';library.parent.mkdir(parents=True);library.write_bytes(b'owned framework')
        executable=prepare_bundle(scratch,source,'io.pathem.transient.fixture.test',['@rpath/Sparkle.framework/Versions/B/Sparkle','/usr/lib/libSystem.B.dylib'])
        self.assertEqual(executable.read_bytes(),source.read_bytes())
        self.assertEqual((executable.parent/'Sparkle.framework/Versions/B/Sparkle').read_bytes(),library.read_bytes())
        self.assertEqual(plistlib.loads((executable.parent.parent/'Info.plist').read_bytes())['CFBundleIdentifier'],'io.pathem.transient.fixture.test')

    def test_missing_framework_refuses_before_launch(self):
        _,source,scratch=self.fixture()
        with self.assertRaisesRegex(ValueError,'Missing native dependency before launch'):
            prepare_bundle(scratch,source,'io.pathem.transient.fixture.test',['@rpath/Sparkle.framework/Versions/B/Sparkle'])

    def test_unknown_dependency_refuses(self):
        _,source,scratch=self.fixture()
        with self.assertRaisesRegex(ValueError,'Unclassified'):
            prepare_bundle(scratch,source,'io.pathem.transient.fixture.test',['/non-system/unknown.dylib'])

    def test_owner_identifier_refuses(self):
        _,source,scratch=self.fixture()
        with self.assertRaisesRegex(ValueError,'private transient'):
            prepare_bundle(scratch,source,'com.scarcrux.pathem',[])

    def test_missing_resources_refuses_before_launch(self):
        _,source,scratch=self.fixture()
        import shutil
        shutil.rmtree(source.parent/'Pathem_Pathem.bundle')
        with self.assertRaisesRegex(ValueError,'Missing native resource bundle'):
            prepare_bundle(scratch,source,'io.pathem.transient.fixture.test',[])

    def test_otool_parser_preserves_load_paths(self):
        output='Pathem:\n\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0.0, current version 2.0.0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
        self.assertEqual(dependency_paths(output),['@rpath/Sparkle.framework/Versions/B/Sparkle','/usr/lib/libSystem.B.dylib'])

class PrivateDomainCleanupTests(unittest.TestCase):
    domain='io.pathem.transient.fixture.'+'a'*32
    def test_empty_structured_export_is_success_even_if_delete_reports_absent(self):
        calls=[]
        def run(args,**kwargs):
            calls.append(args)
            return SimpleNamespace(returncode=0 if 'export' in args else 1,stdout=plistlib.dumps({}),stderr=b'')
        self.assertTrue(clear_private_domain(self.domain,run))
        self.assertEqual(len(calls),4)
        self.assertTrue(any('-currentHost' in call for call in calls))
    def test_surviving_key_is_failure(self):
        def run(args,**kwargs):return SimpleNamespace(returncode=0,stdout=plistlib.dumps({'survived':1}),stderr=b'')
        self.assertFalse(clear_private_domain(self.domain,run))
    def test_wrong_domain_never_calls_defaults(self):
        def run(*args,**kwargs):self.fail('must refuse before accessing preferences')
        with self.assertRaises(ValueError):clear_private_domain('com.scarcrux.pathem',run)
    def test_unparseable_export_is_failure(self):
        def run(args,**kwargs):return SimpleNamespace(returncode=0,stdout=b'not a plist',stderr=b'')
        self.assertFalse(clear_private_domain(self.domain,run))
