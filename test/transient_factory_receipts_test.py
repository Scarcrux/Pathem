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
                detail=' configUnchanged=true' if check==5 else ''
                labels=([f'phase=cycle{cycle}-factory']+([f'phase=cycle{cycle}-suggestion',f'phase=cycle{cycle}-suggestion-failure'] if r['constructor']=='NSSavePanel' else []) if check in (1,2,3) else [f'cycle={cycle}'])
                lines += [f'TSAMPLE: PASS cell={cell} check={check} '+label+detail for label in labels]
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
        text=sample('f18').replace('TSAMPLE: PASS cell=F-f18-de-light-720-short check=1 phase=cycle2-factory','',1)
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


    def absent_cancel_sample(self,visible=True):
        text=sample('f23')
        text=text.replace('PASS cell=F-f23-','FAIL cell=F-f23-')
        # Keep all unrelated checks green; only actual missing Cancel and,
        # when still visible, real dismissal/accumulation remain red.
        text='\n'.join(line.replace('FAIL cell=','PASS cell=') if (' check=5 ' not in line and (not visible or not any(' check='+str(n)+' ' in line for n in [7,8]))) else line for line in text.splitlines())
        for name in ['short','long255']:
            for cycle in range(3):
                text+=f'\nTSAMPLE: SHEET-NO-CANCEL cell=F-f23-de-light-720-{name} cycle={cycle} complete=true equivalent=false keyDownSent=true received=[] response=None visible={str(visible).lower()} buttonCallbacksWithheld=true'
        return text
    def test_missing_cancel_real_sheet_observations_are_product_reds(self):
        self.assertEqual(receipt_errors(self.absent_cancel_sample(),'de',0,True,'f23'),[])
    def test_missing_cancel_implicit_dismissal_does_not_become_cancel_pass(self):
        self.assertEqual(receipt_errors(self.absent_cancel_sample(False),'de',0,True,'f23'),[])
    def test_missing_cancel_sheet_escape_delivery_required(self):
        text=self.absent_cancel_sample().replace('complete=true','complete=false',1)
        self.assertTrue(any('Escape observation incomplete' in e for e in receipt_errors(text,'de',0,True,'f23')))
    def test_missing_cancel_cannot_claim_discard_as_cancel(self):
        text=self.absent_cancel_sample().replace('FAIL cell=F-f23-de-light-720-short check=5','PASS cell=F-f23-de-light-720-short check=5',1)
        self.assertTrue(any('cannot claim native Cancel' in e for e in receipt_errors(text,'de',0,True,'f23')))
