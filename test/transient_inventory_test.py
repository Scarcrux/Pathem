import pathlib
import tempfile
import unittest
from transient_inventory import mask, debug_lines, scan, validate


class InventoryControls(unittest.TestCase):
    def test_strings_comments_and_interpolation(self):
        source = '''// fake.runModal()
/* outer /* inner */ NSAlert() */
let text = "fake.beginSheetModal()"
let interpolated = "value \\(actual.runModal())"
let raw = #"fake.runModal()"#
real.runModal()
'''
        code = mask(source)
        self.assertEqual(len(source), len(code))
        self.assertEqual(source.count('\n'), code.count('\n'))
        self.assertNotIn('fake', code)
        self.assertNotIn('NSAlert', code)
        self.assertIn('actual.runModal()', code)
        self.assertIn('real.runModal()', code)

    def test_debug_else_and_unrelated_conditions(self):
        source = '''#if DEBUG
hidden.runModal()
#else
visible.runModal()
#endif
#if compiler(>=6.4)
current.runModal()
#else
legacy.runModal()
#endif
'''
        self.assertEqual(debug_lines(source), {2})

    def test_nested_debug_and_negation(self):
        source = '''#if DEBUG
#if canImport(AppKit)
hidden.runModal()
#else
alsoHidden.runModal()
#endif
#endif
#if !DEBUG
release.runModal()
#else
debug.runModal()
#endif
'''
        self.assertEqual(debug_lines(source), {3, 5, 11})

    def test_actual_scan_counts_and_explicit_exclusion(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text('let a = NSAlert(); a.runModal(); a.beginSheetModal(for: host)\n')
            (sources/'Harness.swift').write_text('let a = NSAlert(); a.runModal()\n')
            builders, sites, ignored = scan(root, {'Sources/Pathem/Harness.swift': 'fixture harness'})
            self.assertEqual((len(builders), len(sites)), (1, 2))
            self.assertEqual(ignored, {'Sources/Pathem/Harness.swift': 2})

    def test_custom_window_subclasses_and_system_sharing_picker(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text('class Custom: NSPanel {}\nlet panel = Custom()\nlet picker = NSSharingServicePicker(items: [])\npicker.show(relativeTo: rect, of: view)\n')
            builders, sites, _ = scan(root, {})
            self.assertEqual({x['method'] for x in builders.values()}, {'Custom', 'NSSharingServicePicker'})
            self.assertEqual(len(sites), 1)

    def test_new_site_rejected_not_auto_classified(self):
        errors = validate({}, {'new-site': {}}, {'sites': {}})
        self.assertEqual(errors, ['UNCLASSIFIED presentation new-site'])

    def test_stale_site_rejected(self):
        self.assertEqual(validate({}, {}, {'sites': {'old-site': {}}}), ['STALE presentation old-site'])

    def test_orphan_builder_must_be_listed(self):
        self.assertEqual(validate({'builder': {}}, {}, {'sites': {}}),
                         ['UNPRESENTED builder requires reason builder'])
        self.assertEqual(validate({'builder': {}}, {}, {'sites': {}, 'unpresented_builders': {'builder': 'never presented; retained for review'}}), [])

    def test_known_linked_site_passes(self):
        metadata = dict(classification='B', reason='plain localized alert', builders=['builder'],
                        kind='alert', custom_content=False, destructive=False,
                        default_destructive_intended=False)
        metadata['class'] = metadata.pop('classification')
        self.assertEqual(validate({'builder': {}}, {'site': {}}, {'sites': {'site': metadata}}), [])


if __name__ == '__main__':
    unittest.main()
