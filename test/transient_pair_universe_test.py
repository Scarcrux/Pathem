import unittest
from unittest.mock import patch
import transient_pair_universe as universe

class PairUniverseControls(unittest.TestCase):
    def job(self,category,language='de',group=0,only=None):return dict(category=category,language=language,group=group,only=only)
    def pairs(self,*jobs):
        with patch.object(universe,'validate_mounts',return_value=[dict(id='m39',filename=True,group=5),dict(id='m42',filename=False,group=6)]),patch.object(universe,'validate_factories',return_value=[dict(id='f32',filename=False,group=6)]),patch.object(universe,'validate_alerts',return_value=[dict(id='b03',sheet=True),dict(id='b07',sheet=False)]):
            return universe.planned_pairs(jobs)
    def test_core_both_languages_and_real_variants(self):
        pairs=self.pairs(self.job('core'),self.job('core','ja'))
        self.assertEqual(len(pairs),32*8)
        self.assertIn(('A-rename-ja-dark-1100-long255',8),pairs)
        self.assertNotIn(('A-reclaim-ja-dark-1100-long255',8),pairs)
    def test_mount_full_axes_and_selected_group(self):
        pairs=self.pairs(self.job('mounts',group=5))
        self.assertEqual(len(pairs),8*8)
        self.assertIn(('M-m39-de-dark-1100-long255',5),pairs)
        self.assertNotIn(('M-m42-de-dark-1100-short',5),pairs)
    def test_factory_filename_axis_matches_recipe(self):
        pairs=self.pairs(self.job('factories',only='f32'))
        self.assertEqual(len(pairs),4*8)
        self.assertNotIn(('F-f32-de-dark-1100-long255',5),pairs)
    def test_B_structure_cannot_claim_behaviour(self):
        pairs=self.pairs(self.job('b'))
        self.assertEqual(len(pairs),4*3+2*8)
        self.assertNotIn(('B-b03-de-720',8),pairs)
        self.assertIn(('B-b03-de-720-lifecycle',8),pairs)
        self.assertNotIn(('B-b07-de-720-lifecycle',8),pairs)
    def test_B_non_german_has_no_lifecycle(self):
        pairs=self.pairs(self.job('b','ja'))
        self.assertEqual(len(pairs),4*3)
        self.assertNotIn(('B-b03-ja-720-lifecycle',5),pairs)
    def test_lifecycle_has_only_actually_emitted_checks(self):
        self.assertEqual(self.pairs(self.job('lifecycle',only='close'),self.job('lifecycle',only='quit')),{('L-close',4),('L-close',5),('L-quit',5)})
    def test_unknown_or_empty_plan_selection_refused(self):
        for job in [self.job('missing'),self.job('mounts',only='m999'),self.job('factories',group=999),self.job('core','en'),self.job('lifecycle',only='missing')]:
            with self.assertRaises(ValueError):self.pairs(job)
    def test_setup_and_predicate_checks_are_not_product_universe(self):
        pairs=self.pairs(self.job('mounts'),self.job('b'),self.job('core'))
        self.assertFalse(any(number==0 or cell.startswith('predicate-') for cell,number in pairs))


class PlanAdmissionControls(unittest.TestCase):
    def job(self):return dict(category='mounts',language='de',group=0,only='m39',label='clean-de-full-mounts-g0-m39')
    def test_canonical_plan_accepted(self):universe.validate_jobs([self.job()])
    def test_empty_and_duplicate_plan_rejected(self):
        for jobs in [[],[self.job(),self.job()]]:
            with self.assertRaises(ValueError):universe.validate_jobs(jobs)
    def test_noncanonical_or_unknown_job_rejected(self):
        for change in [dict(label='previous-run'),dict(group=True),dict(group=-1),dict(language='unknown'),dict(category='unknown'),dict(only=''),dict(pilot=True)]:
            with self.assertRaises(ValueError):universe.validate_jobs([{**self.job(),**change}])
    def test_core_cannot_silently_ignore_selector(self):
        row=dict(category='core',language='de',group=0,only='m39',label='clean-de-full-core-g0-m39')
        with self.assertRaises(ValueError):universe.validate_jobs([row])
    def test_lifecycle_cannot_silently_ignore_group_or_locale(self):
        for language,group in [('ja',0),('de',1)]:
            row=dict(category='lifecycle',language=language,group=group,only='close',label=f'clean-{language}-full-lifecycle-g{group}-close')
            with self.assertRaises(ValueError):universe.validate_jobs([row])
