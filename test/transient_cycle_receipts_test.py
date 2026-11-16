import re
import unittest
from transient_mounts import receipt_errors as mounts
from transient_factories import receipt_errors as factories
from transient_full_alerts import receipt_errors as alerts
from transient_mounts_test import sample as mount_sample
from transient_factory_receipts_test import sample as factory_sample
from transient_full_alert_receipts_test import transcript as alert_sample


def change_check(log, check, before, after):
    return '\n'.join(line.replace(before,after) if re.match(r'^TSAMPLE: (?:PASS|FAIL) cell=[MFB]-\S+ check='+str(check)+r' ',line) else line for line in log.splitlines())

class ExactCycleControls(unittest.TestCase):
    def cases(self):
        return [(mount_sample(),lambda s:mounts(s,'de',0,True,'m15')),
                (factory_sample(),lambda s:factories(s,'de',0,True,'f01')),
                (alert_sample(),lambda s:alerts(s,'de'))]
    def test_authentic_three_cycles_pass(self):
        for log,validate in self.cases():
            with self.subTest(validate=validate):self.assertEqual(validate(log),[])
    def test_repeated_initial_ownership_cannot_replace_represent(self):
        for log,validate in self.cases():
            with self.subTest(validate=validate):
                replay=change_check(log,4,'cycle=2','cycle=0')
                self.assertNotEqual(replay,log)
                self.assertTrue(any('exact cycle/phase' in e for e in validate(replay)))
    def test_duplicate_geometry_phase_cannot_replace_final_cycle(self):
        for log,validate in self.cases():
            with self.subTest(validate=validate):
                replay=change_check(log,1,'phase=cycle2-','phase=cycle0-')
                self.assertNotEqual(replay,log)
                self.assertTrue(any('exact cycle/phase' in e for e in validate(replay)))
    def test_geometry_phase_cannot_be_untagged(self):
        for log,validate in self.cases():
            with self.subTest(validate=validate):
                self.assertTrue(any('exact cycle/phase' in e for e in validate(change_check(log,2,'phase=','untagged='))))
    def test_duplicate_phase_tag_is_refused(self):
        for log,validate in self.cases():
            with self.subTest(validate=validate):
                self.assertTrue(any('exact cycle/phase' in e for e in validate(change_check(log,3,'phase=','phase=other phase='))))
    def test_save_panel_distinct_suggestion_stages_required(self):
        log=factory_sample('f18')
        replay=change_check(log,1,'-suggestion-failure','-suggestion')
        self.assertTrue(any('exact cycle/phase' in e for e in factories(replay,'de',0,True,'f18')))
