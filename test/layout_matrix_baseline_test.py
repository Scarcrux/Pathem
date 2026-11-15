import unittest
from layout_matrix_baseline import compare, failing_set


class KnownFindingsTests(unittest.TestCase):
    baseline = {'findings': [{'id': 'fixture-ID', 'cell': 'fixture', 'check': 4, 'reason': 'known short label'}]}
    red = 'LAYOUTMATRIX: FAIL fixture check4 count=1 frame=(0,0,20,3)'

    def test_exact_known_failure(self):
        self.assertTrue(compare(self.red, self.baseline)[0])

    def test_clean_without_findings(self):
        self.assertTrue(compare('LAYOUTMATRIX: PASS fixture check4', {'findings': []})[0])

    def test_new_failure_rejected(self):
        ok, new, stale = compare(self.red + '\nLAYOUTMATRIX: FAIL other check2', self.baseline)
        self.assertFalse(ok)
        self.assertEqual(new, [('other', 2)])
        self.assertEqual(stale, [])

    def test_stale_failure_rejected(self):
        ok, new, stale = compare('LAYOUTMATRIX: PASS fixture check4', self.baseline)
        self.assertFalse(ok)
        self.assertEqual(new, [])
        self.assertEqual(stale, [(('fixture', 4), 'fixture-ID')])

    def test_wrong_check_is_new_and_stale(self):
        ok, new, stale = compare('LAYOUTMATRIX: FAIL fixture check2', self.baseline)
        self.assertFalse(ok)
        self.assertEqual(new, [('fixture', 2)])
        self.assertEqual(len(stale), 1)

    def test_duplicate_receipts_rejected(self):
        with self.assertRaises(ValueError):
            failing_set(self.red + '\n' + self.red)

    def test_malformed_receipt_rejected(self):
        with self.assertRaises(ValueError):
            failing_set('LAYOUTMATRIX: FAIL fixture missing-check')

    def test_selection_cannot_be_baselined(self):
        with self.assertRaises(ValueError):
            compare('LAYOUTMATRIX: FAIL fixture check6', {'findings': [dict(self.baseline['findings'][0], check=6)]})


if __name__ == '__main__':
    unittest.main()
