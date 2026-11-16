import unittest
from transient_deadline import bounded_native_timeout as allowance,validate_native_timeout

class DeadlineControls(unittest.TestCase):
    def test_standalone_keeps_existing_180_second_cap(self):self.assertEqual(allowance(),180)
    def test_large_budget_does_not_raise_native_cap(self):self.assertEqual(allowance(deadline=2250,now=0),180)
    def test_remaining_budget_reduces_native_wait(self):self.assertEqual(allowance(deadline=2250,now=2100),90)
    def test_exhausted_cleanup_reserve_admits_no_native(self):self.assertIsNone(allowance(deadline=2250,now=2190))
    def test_subsecond_wait_is_not_admitted(self):self.assertIsNone(allowance(deadline=2250,now=2189.1))
    def test_exact_one_second_is_admitted(self):self.assertEqual(allowance(deadline=2250,now=2189),1)
    def test_prep_elapsed_recomputes_allowance(self):
        first=allowance(deadline=2250,now=2100)
        self.assertEqual(allowance(first,deadline=2250,now=2140),50)
        self.assertIsNone(allowance(first,deadline=2250,now=2200))
    def test_invalid_native_caps_refused(self):
        for value in [0,-1,181,True,float('inf'),float('nan'),'180']:
            with self.assertRaises(ValueError):validate_native_timeout(value)
    def test_invalid_deadline_or_margin_refused(self):
        for value in [True,float('inf'),float('nan'),'2250']:
            with self.assertRaises(ValueError):allowance(deadline=value,now=0)
        for value in [-1,True,float('inf'),float('nan'),'60']:
            with self.assertRaises(ValueError):allowance(deadline=2250,cleanup_margin=value,now=0)
