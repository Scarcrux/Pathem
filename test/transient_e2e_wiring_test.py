"""Headless completion-policy and static wiring controls; never execute the E2E app."""
from pathlib import Path
import re
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[1]

class TransientE2EWiringControls(unittest.TestCase):
    def source(self):return (ROOT/'test/e2e/run.sh').read_text()
    def test_full_gate_is_wired_once_with_bound_and_reviewed_baseline(self):
        lines=[line for line in self.source().splitlines() if 'scenario "transient surface known-findings gate"' in line]
        self.assertEqual(len(lines),1)
        line=lines[0]
        self.assertIn('PATHEM_SCENARIO_TIMEOUT=2400 scenario',line)
        self.assertIn('python3 "$ROOT/test/transient_surfaces_full.py"',line)
        self.assertIn('--known-findings "$ROOT/test/transient_known_findings.json"',line)
        self.assertNotIn("caffeinate",line)  # Alarm must reach the Python supervisor.
        self.assertNotRegex(line,r'--record|--surface|--plan|--probe|--only|\|\||true|RESULT: \(PASS\|SKIP\)')
    def completion(self,status,text):
        source=self.source();start=source.index('scenario_succeeded() {');end=source.index('\n}\n',start)+3
        function=source[start:end]
        script=function+'\nscenario_succeeded "$1" "$2" "RESULT: PASS transient known-findings comparison"\n'
        return subprocess.run(['bash','-c',script,'completion-control',str(status),text],capture_output=True).returncode==0
    def test_exact_comparison_pass_accepted(self):
        self.assertTrue(self.completion(0,'TRANSIENT FULL: native=1 pairs=2 retained\nRESULT: PASS transient known-findings comparison'))
    def test_native_nonzero_cannot_be_hidden_by_pass_text(self):
        self.assertFalse(self.completion(1,'RESULT: PASS transient known-findings comparison'))
    def test_final_fail_overrides_earlier_pass(self):
        self.assertFalse(self.completion(0,'RESULT: PASS transient known-findings comparison\nRESULT: FAIL final'))
    def test_unrelated_generic_pass_does_not_count(self):
        self.assertFalse(self.completion(0,'RESULT: PASS'))
    def test_skip_does_not_count(self):
        self.assertFalse(self.completion(0,'RESULT: SKIP transient known-findings comparison'))
