import unittest
from transient_mounts import validate, receipt_errors


def sample():
    r=next(r for r in validate() if r['id']=='m15')
    cell='M-m15-de-light-720-short'
    lines=['TSAMPLE: PASS cell=predicate-startup check=0 sheets=0 argumentOnlyFirstRunState=true']
    lines.append('TSAMPLE: PASS cell=mount-metadata-control check=0 xattr empty-directory symlink discriminate')
    lines += [f'TSAMPLE: PASS cell={cell} check={n} '+(f'phase=cycle{cycle}-mounted' if n in (1,2,3) else f'cycle={cycle}') for cycle in range(3) for n in range(9)]
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

    def test_metadata_counterexample_control_required(self):
        log='\n'.join(x for x in sample().splitlines() if 'mount-metadata-control' not in x)
        self.assertTrue(any('metadata control' in e for e in receipt_errors(log,'de',0,True,'m15')))

    def test_changed_content_must_be_observed_per_cycle(self):
        recipe=next(r for r in validate() if r['id']=='m39')
        lines=['TSAMPLE: PASS cell=predicate-startup check=0 sheets=0 argumentOnlyFirstRunState=true',
               'TSAMPLE: PASS cell=mount-metadata-control check=0 counterexamples delivered']
        for name in ['short','long255']:
            cell=f'M-m39-de-light-720-{name}'
            for cycle in range(3):
                lines += [f'TSAMPLE: PASS cell={cell} check={n} '+(f'phase=cycle{cycle}-mounted' if n in (1,2,3) else f'cycle={cycle}') for n in range(9)]
                lines += [f'TSAMPLE: PASS cell={cell} check={n} phase=cycle{cycle}-content-changed' for n in [1,2,3]]
                lines.append(f'TSAMPLE: PASS cell=mount-content check=0 cell={cell} cycle={cycle} changed-content delivered=true')
            lines.append(f'TSAMPLE: COVERED class=A site={recipe["site"]} cell={cell}')
        text='\n'.join(lines)
        self.assertEqual(receipt_errors(text,'de',0,True,'m39'),[])
        omitted='\n'.join(x for x in lines if not ('cell=mount-content' in x and 'cycle=2' in x))
        self.assertTrue(any('changed content delivery incomplete' in e for e in receipt_errors(omitted,'de',0,True,'m39')))
        omitted='\n'.join(x for x in lines if not ('-content-changed' in x and 'check=2' in x))
        self.assertTrue(any('three-cycle' in e for e in receipt_errors(omitted,'de',0,True,'m39')))
