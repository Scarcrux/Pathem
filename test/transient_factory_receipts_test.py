import unittest
from transient_factories import validate, receipt_errors

def sample(profile='f01'):
    r=next(r for r in validate() if r['id']==profile)
    lines=['TSAMPLE: PASS cell=predicate-startup check=0 sheets=0',
           'TSAMPLE: PASS cell=predicate-6-binding check=6 good=true bad=false']
    for name in (['short','long255'] if r['filename'] else ['short']):
        cell=f'F-{profile}-de-light-720-{name}'
        for cycle in range(3):
            for check in range(9):
                repeat=3 if r['constructor']=='NSSavePanel' and check in (1,2,3) else 1
                detail=' configUnchanged=true' if check==5 else ''
                lines += [f'TSAMPLE: PASS cell={cell} check={check} cycle={cycle}'+detail]*repeat
        lines.append(f'TSAMPLE: COVERED class=A site={r["site"]} cell={cell}')
    return '\n'.join(lines)

class FactoryReceiptControls(unittest.TestCase):
    def test_complete_three_cycle_treatment(self):
        self.assertEqual(receipt_errors(sample(),'de',0,True,'f01'),[])
    def test_missing_cycle_rejected(self):
        text=sample().replace('TSAMPLE: PASS cell=F-f01-de-light-720-short check=5 cycle=2','')
        self.assertTrue(any('three-cycle' in e for e in receipt_errors(text,'de',0,True,'f01')))
    def test_changed_suggestion_must_be_checked(self):
        self.assertEqual(receipt_errors(sample('f18'),'de',0,True,'f18'),[])
        text=sample('f18').replace('TSAMPLE: PASS cell=F-f18-de-light-720-short check=1 cycle=2','',1)
        self.assertTrue(any('three-cycle' in e for e in receipt_errors(text,'de',0,True,'f18')))
    def test_setup_failure_not_baseline_eligible(self):
        text=sample().replace('PASS cell=F-f01-de-light-720-short check=0','FAIL cell=F-f01-de-light-720-short check=0',1)
        self.assertTrue(any('setup failed' in e for e in receipt_errors(text,'de',0,True,'f01')))
    def test_duplicate_claim_rejected(self):
        text=sample()+'\n'+sample().splitlines()[-1]
        self.assertTrue(any('site coverage' in e for e in receipt_errors(text,'de',0,True,'f01')))
    def test_startup_control_required(self):
        text='\n'.join(sample().splitlines()[1:])
        self.assertTrue(any('control missing' in e for e in receipt_errors(text,'de',0,True,'f01')))
    def test_timeout_refused(self):
        self.assertTrue(any('timed out' in e for e in receipt_errors(sample()+'\ntimedOut=true','de',0,True,'f01')))
    def test_wrong_treatment_refused(self):
        self.assertTrue(receipt_errors(sample(),'ja',0,True,'f01'))

    def test_cancel_configuration_observation_required(self):
        text=sample().replace(' configUnchanged=true','',1)
        self.assertTrue(any('configuration proof incomplete' in e for e in receipt_errors(text,'de',0,True,'f01')))
    def test_changed_configuration_cannot_claim_cancel_pass(self):
        text=sample().replace('configUnchanged=true','configUnchanged=false',1)
        self.assertTrue(any('contradicts changed configuration' in e for e in receipt_errors(text,'de',0,True,'f01')))
    def test_changed_configuration_remains_a_product_red(self):
        text=sample().replace('PASS cell=F-f01-de-light-720-short check=5 cycle=0 configUnchanged=true',
            'FAIL cell=F-f01-de-light-720-short check=5 cycle=0 configUnchanged=false')
        self.assertEqual(receipt_errors(text,'de',0,True,'f01'),[])
