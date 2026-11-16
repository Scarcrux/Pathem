import unittest
from transient_full_plan import classify_coverage

class CoverageControls(unittest.TestCase):
    def setUp(self):
        self.inventory = {'mount': {'class':'A'}, 'core': {'class':'A'}, 'delegated': {'class':'A'}, 'plain': {'class':'B'}}
        self.adapters = [{'site':'mount'}]
        self.special = [dict(site='core', coverage='core', reason='real core'), dict(site='delegated', coverage='task2', reason='accepted main-window check')]
    def test_complete_accounting(self):
        self.assertEqual(classify_coverage(self.inventory,self.adapters,[],self.special),dict(A_total=3,A_native=2,A_delegated=1,B_total=1))
    def test_new_A_is_not_covered_by_existing_counts(self):
        self.inventory['new']={'class':'A'}
        with self.assertRaisesRegex(ValueError,'coverage missing'):classify_coverage(self.inventory,self.adapters,[],self.special)
    def test_wrong_class_cannot_be_covered(self):
        self.inventory['mount']['class']='C'
        with self.assertRaisesRegex(ValueError,'unclassified'):classify_coverage(self.inventory,self.adapters,[],self.special)
    def test_duplicate_special_refused(self):
        self.special.append(self.special[0])
        with self.assertRaisesRegex(ValueError,'duplicated'):classify_coverage(self.inventory,self.adapters,[],self.special)
    def test_overlap_refused(self):
        self.adapters.append({'site':'core'})
        with self.assertRaisesRegex(ValueError,'overlaps'):classify_coverage(self.inventory,self.adapters,[],self.special)
    def test_reason_required(self):
        self.special[1]['reason']=''
        with self.assertRaisesRegex(ValueError,'reason missing'):classify_coverage(self.inventory,self.adapters,[],self.special)

    def test_focused_mount_keeps_required_A_variants(self):
        from transient_full_plan import focused_plan
        jobs=focused_plan(['m39'])
        self.assertEqual({(r['category'],r['language'],r['only'],r['group']) for r in jobs},
                         {('mounts','de','m39',0),('mounts','ja','m39',0)})
    def test_focused_B_keeps_all_shipped_languages(self):
        from transient_full_plan import focused_plan
        jobs=focused_plan(['b03'])
        self.assertEqual({r['language'] for r in jobs},{'de','ja','en','fr','es','zh-Hans'})
    def test_unknown_and_duplicate_surface_refused(self):
        from transient_full_plan import focused_plan
        for selection in [['unknown'],['m39','m39']]:
            with self.assertRaises(ValueError):focused_plan(selection)
