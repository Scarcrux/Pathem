import unittest
from transient_mounts import validate, receipt_errors


def sample():
    r=next(r for r in validate() if r['id']=='m15')
    cell='M-m15-de-light-720-short'
    lines=['TSAMPLE: PASS cell=predicate-startup check=0 sheets=0 argumentOnlyFirstRunState=true']
    lines += [f'TSAMPLE: PASS cell={cell} check={n} cycle={cycle}' for cycle in range(3) for n in range(9)]
    lines += [f'TSAMPLE: COVERED class=A site={r["site"]} cell={cell}']
    return '\n'.join(lines)

class MountTreatmentControls(unittest.TestCase):
    def test_complete_three_cycle_treatment(self):
        self.assertEqual(receipt_errors(sample(),'de',0,True,'m15'),[])

    def test_missing_surface_rejected(self):
        self.assertTrue(receipt_errors('','de',0,True,'m15'))

    def test_missing_single_cycle_check_rejected(self):
        text=sample().replace('TSAMPLE: PASS cell=M-m15-de-light-720-short check=5 cycle=2','')
        self.assertTrue(any('three-cycle' in e for e in receipt_errors(text,'de',0,True,'m15')))

    def test_wrong_group_rejected(self):
        self.assertTrue(receipt_errors(sample(),'de',1,True))

    def test_unknown_only_id_rejected(self):
        self.assertEqual(receipt_errors(sample(),'de',0,True,'missing'),['requested mount set is empty'])

    def test_duplicate_site_claim_rejected(self):
        text=sample()+'\n'+sample().splitlines()[-1]
        self.assertTrue(any('site coverage' in e for e in receipt_errors(text,'de',0,True,'m15')))

    def test_startup_marker_required(self):
        self.assertTrue(any('startup' in e for e in receipt_errors('\n'.join(sample().splitlines()[1:]),'de',0,True,'m15')))
