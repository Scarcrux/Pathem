import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from transient_core_receipts import IDENTITIES,cells,core_sites,receipt_errors

class CoreReceiptControls(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        (self.root/'test').mkdir();(self.root/'Sources/Pathem').mkdir(parents=True)
        inventory={};special=[]
        for (file,method),kind in IDENTITIES.items():
            site=f'Sources/Pathem/{file}:1:1:{method}'
            inventory[site]={'class':'A'};special.append(dict(site=site,coverage='core',reason='fixture'))
        (self.root/'test/transient_inventory.json').write_text(json.dumps(dict(sites=inventory)))
        (self.root/'test/transient_full_special_sites.json').write_text(json.dumps(dict(sites=special)))
        (self.root/'Sources/Pathem/TransientSurfaceSample.swift').write_text('''func runSurface() {
            RenameDialogController(); browser.presentSheet(); CleanupController.deleteNowAlert()
            CleanupController.presentDeleteNowAlert(); browser.askConflictResolution()
            suggestion.debugDeliver(); suggestion.debugFail()
        }''')
    def transcript(self,pilot=False):
        sites=core_sites(self.root);lines=[]
        for cell,kind in cells('de',pilot).items():
            for cycle in range(3):
                phases=[f'cycle{cycle}-initial']
                if kind=='rename':
                    phases += [f'cycle{cycle}-suggestion',f'cycle{cycle}-failure']
                    if cycle==1:phases.append('cycle1-typed')
                for phase in phases:
                    lines += [f'TSAMPLE: PASS cell={cell} check={n} phase={phase} measured' for n in [1,2,3]]
                lines += [f'TSAMPLE: PASS cell={cell} check={n} cycle={cycle} actual' for n in [4,5,6,7,8]]
                lines += [f'TSAMPLE: CORE-SITE cell={cell} cycle={cycle} site={site}' for site in sites[kind]]
        return '\n'.join(lines)
    def errors(self,text,pilot=False):return receipt_errors(text,'de',pilot,self.root)
    def test_complete_full_and_pilot(self):
        self.assertEqual(self.errors(self.transcript()),[])
        self.assertEqual(self.errors(self.transcript(True),True),[])
    def test_wrong_variant_same_count_refused(self):
        self.assertTrue(any('cell set' in e for e in self.errors(self.transcript().replace('-dark-1100-','-unreviewed-1100-'))))
    def test_missing_cycle_refused(self):
        text='\n'.join(x for x in self.transcript().splitlines() if not ('cycle=2' in x or 'phase=cycle2-' in x))
        self.assertTrue(any('cycle/phase' in e for e in self.errors(text)))
    def test_missing_suggestion_or_typed_frame_refused(self):
        for phase in ['cycle0-suggestion','cycle1-typed','cycle2-failure']:
            text='\n'.join(x for x in self.transcript().splitlines() if 'phase='+phase not in x)
            self.assertTrue(any('cycle/phase' in e for e in self.errors(text)))
    def test_duplicate_cycle_cannot_replace_missing_cycle(self):
        self.assertTrue(any('cycle/phase' in e for e in self.errors(self.transcript().replace('cycle=2','cycle=1').replace('phase=cycle2-','phase=cycle1-'))))
    def test_missing_or_wrong_site_claim_refused(self):
        for text in ['\n'.join(x for x in self.transcript().splitlines() if 'CORE-SITE' not in x),self.transcript().replace('site=Sources/Pathem/','site=Wrong/')]:
            self.assertTrue(any('production-site' in e for e in self.errors(text)))
    def test_changed_core_delegation_refused(self):
        p=self.root/'test/transient_full_special_sites.json';data=json.loads(p.read_text());data['sites'][0]['coverage']='task2';p.write_text(json.dumps(data))
        self.assertTrue(any('source contract' in e for e in self.errors('')))
    def test_missing_production_call_not_hidden_by_comment(self):
        p=self.root/'Sources/Pathem/TransientSurfaceSample.swift';p.write_text(p.read_text().replace('browser.askConflictResolution()','/* browser.askConflictResolution() */'))
        self.assertTrue(any('source contract' in e for e in self.errors('')))

class PredicateIdentityControls(unittest.TestCase):
    def transcript(self):
        lines=[f'TSAMPLE: PASS cell=predicate-{n} check={n} control' for n in range(1,9)]
        for cell,number in [('predicate-file-opening',0),('predicate-3-system',3),('predicate-1-viewport',1),('predicate-8-multiplicity',8),('predicate-4-appearance',4),('predicate-1-tooltip',1),('predicate-4-presentation',4)]:
            lines.append(f'TSAMPLE: PASS cell={cell} check={number} control')
        lines += ['TSAMPLE: START language=de cancel=Cancel ','TSAMPLE: SUMMARY fixture','RESULT: PASS (1/1)']
        return '\n'.join(lines)
    def errors(self,text):
        from transient_surfaces_sample import validate
        return validate(text,0,'clean','de',False,'Cancel',full=False,category='factories')[0]
    def test_all_distinct_predicates(self):self.assertEqual(self.errors(self.transcript()),[])
    def test_duplicate_predicate_cannot_replace_missing_one(self):
        self.assertTrue(any('predicate controls' in e for e in self.errors(self.transcript().replace('cell=predicate-2 check=2','cell=predicate-1 check=1'))))
    def test_wrong_check_number_refused(self):
        self.assertTrue(any('predicate controls' in e for e in self.errors(self.transcript().replace('cell=predicate-2 check=2','cell=predicate-2 check=1'))))
    def test_failed_predicate_refused(self):
        self.assertTrue(any('predicate controls' in e for e in self.errors(self.transcript().replace('PASS cell=predicate-2','FAIL cell=predicate-2'))))
