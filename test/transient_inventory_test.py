import pathlib
import json
import subprocess
import sys
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

    def test_compound_debug_conditions_do_not_hide_release_presentations(self):
        source = """#if DEBUG || os(macOS)
possibleRelease.runModal()
#else
alsoPossible.runModal()
#endif
#if DEBUG && canImport(AppKit)
hidden.runModal()
#elseif !DEBUG
release.runModal()
#else
unreachable.runModal()
#endif
"""
        self.assertEqual(debug_lines(source), {7, 11})

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

    def test_system_and_metatype_window_factories_are_builders(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text("let kind: NSWindow.Type = NSWindow.self\nlet window = kind.init(contentRect: rect)\nlet panel = QLPreviewPanel.shared()\nwindow.makeKeyAndOrderFront(nil)\npanel.makeKeyAndOrderFront(nil)\n")
            builders, sites, _ = scan(root, {})
            self.assertEqual({x['method'] for x in builders.values()}, {'kind.init', 'QLPreviewPanel.shared'})
            self.assertEqual(len(sites), 2)

    def test_async_system_panel_begin_counts_without_gesture_false_positive(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text("let chooser = NSOpenPanel()\nchooser.begin { response in }\ngestureTracker.begin(event)\n")
            _, sites, _ = scan(root, {})
            self.assertEqual(len(sites), 1)
            self.assertEqual(next(iter(sites.values()))['method'], 'begin')

    def test_new_site_rejected_not_auto_classified(self):
        errors = validate({}, {'new-site': {}}, {'sites': {}})
        self.assertEqual(errors, ['UNCLASSIFIED presentation new-site'])

    def test_wrappers_have_separate_transitive_callers(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text('''func present(_ alert: NSAlert) { alert.runModal() }
func forward(_ alert: NSAlert) { present(alert) }
let concrete = NSAlert()
forward(concrete)
''')
            _, sites, _ = scan(root, {})
            self.assertEqual(len(sites), 3)
            self.assertEqual(sum(x['role']=='wrapper' for x in sites.values()), 2)
            caller = next(x for x in sites.values() if x['role']=='caller')
            self.assertEqual(caller['receiver'], 'concrete')
            self.assertEqual(len(caller['wrapper_path']), 2)

    def test_menu_pass_through_wrapper_keeps_class_on_caller(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text("func popup(_ menu: NSMenu) { menu.popUp(positioning: nil, at: point, in: view) }\nlet built = NSMenu()\npopup(built)\n")
            builders, sites, _ = scan(root, {})
            self.assertEqual(len(sites), 2)
            self.assertEqual({x['role'] for x in sites.values()}, {'wrapper', 'caller'})
            self.assertEqual(len(builders), 1)

    def test_wrapper_class_is_rejected(self):
        sites={'site':{'role':'wrapper'}}
        self.assertEqual(validate({},sites,{'sites':{'site':{'role':'wrapper','class':'A'}}}),
                         ['WRAPPER must remain unclassed site'])
        self.assertEqual(validate({},sites,{'sites':{'site':{'role':'wrapper'}}}), [])

    def test_multiargument_wrapper_with_nested_factory_caller(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder)
            sources=root/'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'Example.swift').write_text('''func present(_ alert: NSAlert, for host: NSWindow) { alert.beginSheetModal(for: host) }
func forward(_ alert: NSAlert, for host: NSWindow) { present(alert, for: host) }
forward(factory.makeAlert(value: other()), for: host)
''')
            _,sites,_=scan(root,{})
            caller=next(x for x in sites.values() if x['role']=='caller')
            self.assertEqual(caller['receiver'],'factory.makeAlert(value: other())')
            self.assertEqual(len(caller['wrapper_path']),2)

    def test_cursor_confirm_callers_keep_individual_intent_and_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            (sources/'CursorConfirm.swift').write_text('class CursorConfirm { func ask() { let pop = NSPopover(); pop.show(relativeTo: rect, of: view) } }\n')
            (sources/'Example.swift').write_text('self.cursorConfirm.ask(message: "Delete")\ncursorConfirm.ask(message: "Keep Both")\nother.ask()\n#if DEBUG\ncursorConfirm.ask(message: "Harness")\n#endif\n')
            builders, sites, ignored = scan(root, {})
            callers = [x for x in sites.values() if x.get('role') == 'factory-caller']
            self.assertEqual(len(callers), 2)
            self.assertEqual(len(sites), 3)
            for caller in callers:
                self.assertEqual(caller['factory_builders'], list(builders))
                self.assertEqual(len(caller['presentation_path']), 1)
            self.assertEqual(ignored, {'Sources/Pathem/Example.swift': 1})

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

    def test_real_cli_rejects_stale_implicit_attachment(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            sources = root / 'Sources/Pathem'
            sources.mkdir(parents=True)
            source = sources / 'Example.swift'
            source.write_text('let menu = NSMenu()\nhost.menu = menu\n')
            builders, sites, ignored = scan(root, {})
            key = next(iter(builders))
            metadata = {'sites': {}, 'ignored_counts': ignored, 'implicit_builders': {
                key: {'status': 'implicit presentation', 'reason': 'Fixture native menu',
                      'attachments': [{'file': 'Sources/Pathem/Example.swift', 'line': 2,
                                       'expression': 'host.menu = menu'}]}}}
            manifest = root / 'inventory.json'
            table = root / 'inventory.md'
            manifest.write_text(json.dumps(metadata))
            command = [sys.executable, str(pathlib.Path(__file__).with_name('transient_inventory.py')),
                       '--root', str(root), '--manifest', str(manifest), '--table', str(table)]
            valid = subprocess.run(command + ['--write-table'], capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
            source.write_text('let menu = NSMenu()\nhost.menu = nil\n')
            invalid = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn('STALE implicit attachment', invalid.stdout)

    def test_real_cli_new_site_and_stale_table_controls(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder)
            sources=root/'Sources/Pathem'
            sources.mkdir(parents=True)
            source=sources/'Example.swift'
            source.write_text('let alert = NSAlert()\nalert.runModal()\n')
            builders,sites,ignored=scan(root,{})
            key=next(iter(sites))
            metadata={'sites':{key:dict(builders=list(builders),kind='alert',custom_content=False,
                                      destructive=False,default_destructive_intended=False,
                                      reason='Fixture plain alert',**{'class':'B'})},'ignored_counts':ignored}
            manifest=root/'inventory.json'
            table=root/'inventory.md'
            manifest.write_text(json.dumps(metadata))
            command=[sys.executable,str(pathlib.Path(__file__).with_name('transient_inventory.py')),
                     '--root',str(root),'--manifest',str(manifest),'--table',str(table)]
            written=subprocess.run(command+['--write-table'],capture_output=True,text=True)
            self.assertEqual(written.returncode,0,written.stdout+written.stderr)
            self.assertEqual(subprocess.run(command,capture_output=True).returncode,0)
            table.write_text(table.read_text()+'unreviewed change\n')
            stale=subprocess.run(command,capture_output=True,text=True)
            self.assertNotEqual(stale.returncode,0)
            self.assertIn('STALE checked-in table',stale.stdout)
            source.write_text(source.read_text()+'let added = NSAlert()\nadded.runModal()\n')
            new=subprocess.run(command,capture_output=True,text=True)
            self.assertNotEqual(new.returncode,0)
            self.assertIn('UNCLASSIFIED presentation',new.stdout)


if __name__ == '__main__':
    unittest.main()
