import json
from pathlib import Path
import tempfile
import unittest
from transient_factories import ROOT, validate

class FactoryProvenanceTests(unittest.TestCase):
    def fixture(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        root=Path(temp.name);(root/'test').mkdir()
        records=json.loads((ROOT/'test/transient_factories.json').read_text())
        for name in ['transient_factories.json','transient_inventory.json']:
            (root/'test'/name).write_bytes((ROOT/'test'/name).read_bytes())
        files={r['file'] for r in records['factories']}|{'Sources/Pathem/TransientSurfaceFullFactories.swift'}
        for file in files:
            target=root/file;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/file).read_bytes())
        return root,records

    def test_reviewed_factories_match_production_and_adapters(self):
        rows=validate();self.assertEqual(len(rows),21);self.assertEqual(len({r['site'] for r in rows}),19)

    def test_missing_profile_is_rejected(self):
        root,r=self.fixture();r['factories'].pop();(root/'test/transient_factories.json').write_text(json.dumps(r))
        with self.assertRaisesRegex(ValueError,'adapter set'):validate(root)

    def test_removed_cancel_guard_is_rejected(self):
        root,r=self.fixture();p=root/r['factories'][0]['file'];s=p.read_text();old='guard alert.runModal() == .alertFirstButtonReturn else { return nil }';self.assertIn(old,s);p.write_text(s.replace(old,'_ = alert.runModal()'))
        with self.assertRaisesRegex(ValueError,'Cancel guard changed'):validate(root)

    def test_changed_widget_construction_is_rejected(self):
        root,r=self.fixture();p=root/r['factories'][0]['file'];s=p.read_text();old='stack.spacing = 8';self.assertIn(old,s);p.write_text(s.replace(old,'stack.spacing = 2'))
        with self.assertRaisesRegex(ValueError,'factory changed'):validate(root)

    def test_wrong_factory_call_in_adapter_is_rejected(self):
        root,_=self.fixture();p=root/'Sources/Pathem/TransientSurfaceFullFactories.swift';s=p.read_text();p.write_text(s.replace('TemplatesController.makeEditorDialog','OtherController.makeEditorDialog'))
        with self.assertRaisesRegex(ValueError,'declared production factory'):validate(root)

    def test_unclassified_site_is_rejected(self):
        root,r=self.fixture();r['factories'][0]['site']='Sources/Pathem/Missing.swift:1:1:runModal';(root/'test/transient_factories.json').write_text(json.dumps(r))
        with self.assertRaisesRegex(ValueError,'Unclassified'):validate(root)
