import unittest
from transient_full_alerts import validate,receipt_errors

def transcript(language='de'):
    lines=['TSAMPLE: PASS cell=full-B-contract check=0 all classified B sites']
    for r in validate():
        for size in [720,1100]:
            cell=f'B-{r["id"]}-{language}-{size}'
            lines += [f'TSAMPLE: PASS cell={cell} check={n} fixture' for n in range(4)]
            lines.append(f'TSAMPLE: SITE cell={cell} site={r["site"]} builder={r["builder"]}')
            if language=='de' and r['sheet']:
                lines += [f'TSAMPLE: PASS cell={cell}-lifecycle check={n} cycle={cycle}' for cycle in range(3) for n in range(1,9)]
            lines.append(f'TSAMPLE: COVERED class=B site={r["site"]} mode=structural')
    return '\n'.join(lines)

class FullBReceiptControls(unittest.TestCase):
    def test_all_german_cells_and_behaviour(self):
        self.assertEqual(receipt_errors(transcript(),'de'),[])
    def test_other_catalogs_are_structural_only(self):
        self.assertEqual(receipt_errors(transcript('ja'),'ja'),[])
    def test_unknown_cell_cannot_replace_missing_cell(self):
        log=transcript().replace('B-b01-de-720','B-unreviewed-de-720')
        self.assertTrue(any('cells differ' in e for e in receipt_errors(log,'de')))
    def test_missing_cycle_refused(self):
        log=transcript();line=next(x for x in log.splitlines() if '-lifecycle check=5 cycle=2' in x);log=log.replace(line,'',1)
        self.assertTrue(any('counts incomplete' in e for e in receipt_errors(log,'de')))
    def test_duplicate_coverage_refused(self):
        log=transcript();self.assertTrue(any('site coverage' in e for e in receipt_errors(log+'\n'+log.splitlines()[-1],'de')))
    def test_wrong_builder_refused(self):
        log=transcript().replace(' builder=Sources/Pathem/',' builder=Wrong/Archive/',1)
        self.assertTrue(any('builder provenance' in e for e in receipt_errors(log,'de')))
    def test_failed_setup_not_baseline_eligible(self):
        log=transcript().replace('PASS cell=B-b01-de-720 check=0','FAIL cell=B-b01-de-720 check=0',1)
        self.assertTrue(any('setup failed' in e for e in receipt_errors(log,'de')))
    def test_inventory_control_required(self):
        self.assertTrue(any('inventory control' in e for e in receipt_errors('\n'.join(transcript().splitlines()[1:]),'de')))
