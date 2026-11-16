import copy
import json
from pathlib import Path
import tempfile
import unittest
from transient_full_alerts import ROOT, validate

class FullAlertProvenanceTests(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root/'test').mkdir()
        inventory = json.loads((ROOT/'test/transient_inventory.json').read_text())
        recipes = json.loads((ROOT/'test/transient_full_alerts.json').read_text())
        for file in {r['builder'].split(':')[0] for r in recipes['alerts']}:
            target = root/file
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes((ROOT/file).read_bytes())
        (root/'test/transient_inventory.json').write_text(json.dumps(inventory))
        (root/'test/transient_full_alerts.json').write_text(json.dumps(recipes))
        return root, recipes

    def test_reviewed_inventory_is_exact(self):
        rows = validate()
        self.assertEqual(len(rows),47)
        self.assertEqual(sum(r['sheet'] for r in rows),36)

    def test_missing_site_fails(self):
        root, recipes = self.fixture()
        recipes['alerts'].pop()
        (root/'test/transient_full_alerts.json').write_text(json.dumps(recipes))
        with self.assertRaisesRegex(ValueError,'differ'):
            validate(root)

    def test_duplicate_site_fails(self):
        root, recipes = self.fixture()
        recipes['alerts'].append(copy.deepcopy(recipes['alerts'][0]))
        (root/'test/transient_full_alerts.json').write_text(json.dumps(recipes))
        with self.assertRaisesRegex(ValueError,'differ'):
            validate(root)

    def test_source_body_mutation_fails_without_reclassifying(self):
        root, recipes = self.fixture()
        file, line, *_ = recipes['alerts'][0]['builder'].split(':')
        target = root/file
        lines = target.read_text().splitlines()
        lines[int(line)] += ' // changed production body'
        target.write_text('\n'.join(lines)+'\n')
        with self.assertRaisesRegex(ValueError,'source changed'):
            validate(root)

    def test_wrong_builder_fails(self):
        root, recipes = self.fixture()
        recipes['alerts'][0]['builder'] = recipes['alerts'][1]['builder']
        (root/'test/transient_full_alerts.json').write_text(json.dumps(recipes))
        with self.assertRaisesRegex(ValueError,'provenance'):
            validate(root)

    def test_runtime_rationale_required(self):
        root, recipes = self.fixture()
        recipes['alerts'][0]['fixture'] = ''
        (root/'test/transient_full_alerts.json').write_text(json.dumps(recipes))
        with self.assertRaisesRegex(ValueError,'rationale'):
            validate(root)
