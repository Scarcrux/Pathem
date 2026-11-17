"""Real-scanner disposable-repository controls; never use authentic credentials."""
import json
import os
from pathlib import Path
import random
import string
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import release_safety as safety

SCRIPT = Path(safety.__file__)


class ReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pathem-safety-control-")
        self.repo = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@users.noreply.github.com")
        self.write("safe.txt", "inert content\n")
        self.commit()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True)
        self.assertEqual(result.returncode, 0, "fixture git operation failed; output withheld")
        return result.stdout

    def write(self, path, value):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)
        target.chmod(0o600)

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-qm", "fixture")

    def token(self):
        # Generated non-authentic fixture, no literal key in source or output.
        return "gh" + "p_" + "".join(random.Random(7).sample(string.ascii_letters + string.digits, 36))

    def run_gate(self, *extra):
        result = subprocess.run([sys.executable, str(SCRIPT), "--repo", str(self.repo), *extra],
                                capture_output=True, text=True, timeout=120)
        self.assertNotIn(self.token(), result.stdout + result.stderr, "synthetic secret escaped")
        self.assertNotIn("fixture@example.invalid", result.stdout + result.stderr, "fixture identity escaped")
        self.assertNotIn(str(self.repo), result.stdout + result.stderr, "private path escaped")
        self.assertEqual(result.stderr, "", "unexpected stderr; content withheld")
        return result

    def test_clean(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("history-commits=1", result.stdout)

    def test_current_and_history_token(self):
        self.write("key.txt", 'token="' + self.token() + '"\n')
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL candidate-tree", result.stdout)
        self.assertIn("FAIL all-ref-history", result.stdout)

    def test_deleted_token_stays_in_history(self):
        self.write("key.txt", 'token="' + self.token() + '"\n')
        self.commit()
        self.git("rm", "-q", "key.txt")
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("PASS candidate-tree", result.stdout)
        self.assertIn("FAIL all-ref-history", result.stdout)

    def test_unmerged_ref_is_scanned(self):
        self.git("checkout", "-qb", "private-fixture")
        self.write("key.txt", 'token="' + self.token() + '"\n')
        self.commit()
        self.git("checkout", "-q", "-")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("PASS candidate-tree", result.stdout)
        self.assertIn("FAIL all-ref-history", result.stdout)

    def history_fingerprint(self, path, rule, line=1):
        commit = self.git("log", "-1", "--format=%H", "--", path).decode().strip()
        return f"{commit}:{path}:{rule}:{line}"

    def test_reviewed_history_baseline_passes_only_listed_findings(self):
        self.write("key.txt", 'token="' + self.token() + '"\n')
        self.commit()
        listed = self.history_fingerprint("key.txt", "github-pat")
        self.git("rm", "-q", "key.txt")
        self.commit()
        baseline = self.repo.parent / (self.repo.name + "-baseline.txt")
        baseline.write_text("# reviewed fixture\n" + listed + "\n")
        self.addCleanup(baseline.unlink)
        result = self.run_gate("--history-baseline", str(baseline))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS all-ref-history", result.stdout)
        self.assertIn("reviewed-baseline matched=1 unmatched=0", result.stdout)
        # Control: a new history finding that is not listed still fails.
        self.write("other.txt", 'token="' + self.token() + '"\n')
        self.commit()
        self.git("rm", "-q", "other.txt")
        self.commit()
        result = self.run_gate("--history-baseline", str(baseline))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL all-ref-history findings=1", result.stdout)

    def test_baseline_cannot_hide_a_current_finding(self):
        self.write("key.txt", 'token="' + self.token() + '"\n')
        self.commit()
        baseline = self.repo.parent / (self.repo.name + "-baseline.txt")
        baseline.write_text(self.history_fingerprint("key.txt", "github-pat") + "\n")
        self.addCleanup(baseline.unlink)
        result = self.run_gate("--history-baseline", str(baseline))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL candidate-tree", result.stdout)
        self.assertIn("PASS all-ref-history", result.stdout)

    def test_malformed_baseline_fails_closed(self):
        baseline = self.repo.parent / (self.repo.name + "-baseline.txt")
        baseline.write_text("not-a-fingerprint\n")
        self.addCleanup(baseline.unlink)
        result = self.run_gate("--history-baseline", str(baseline))
        self.assertEqual(result.returncode, 2, result.stdout)

    def test_non_noreply_author(self):
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("new.txt", "safe\n")
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("authorship rule=author-email count=1", result.stdout)
        self.assertIn("authorship rule=committer-email count=1", result.stdout)

    def test_missing_scanner_fails_closed(self):
        result = self.run_gate("--scanner", "pathem-deliberately-absent-scanner")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("gitleaks unavailable", result.stdout)

    def test_untracked_candidate_is_scanned(self):
        self.write("new-key.txt", 'token="' + self.token() + '"\n')
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL candidate-tree", result.stdout)
        self.assertIn("PASS all-ref-history", result.stdout)

    def test_ignored_but_tracked_candidate_is_scanned(self):
        self.write("key.txt", "inert\n")
        self.commit()
        self.write(".gitignore", "key.txt\n")
        self.commit()
        self.write("key.txt", 'token="' + self.token() + '"\n')
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL candidate-tree", result.stdout)

    def test_live_env_expression_no_false_positive(self):
        self.write("Tests/PathemEngineTests/LiveRemoteTests.swift",
                   'private var ftpPassword: String {\n'
                   '    ProcessInfo.processInfo.environment["PATHEM_LIVE_FTP_PASSWORD"] ?? ""\n}\n')
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_live_file_cannot_hide_token(self):
        self.write("Tests/PathemEngineTests/LiveRemoteTests.swift",
                   'private var ftpPassword = "' + self.token() + '"\n')
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL candidate-tree", result.stdout)

    def test_private_path_pattern(self):
        self.write("path.txt", "/" + "Users/fixture-account/private.txt\n")
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("rule=absolute-user-path", result.stdout)
        self.assertNotIn("fixture-account", result.stdout)

    def test_personal_email_pattern(self):
        self.write("contact.txt", "fixture" + "@gmail.com\n")
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("rule=personal-email-address", result.stdout)
        self.assertNotIn("fixture" + "@gmail.com", result.stdout)

    def test_reserved_fixture_examples_are_clean(self):
        self.write("fixtures.swift", '// GoogleDrive-user@example.invalid\n'
                   'let home = "/fixture/home"\n'
                   'let folder = "/fixture/home/Library/CloudStorage/GoogleDrive-user@example.invalid"\n')
        self.commit()
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_shallow_history_fails(self):
        shallow = self.repo / "shallow"
        self.git("clone", "-q", "--depth=1", self.repo.as_uri(), str(shallow))
        result = self.run_gate("--repo", str(shallow))
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("shallow history", result.stdout)

    def test_missing_report_and_scanner_error_are_suppressed(self):
        scanner = self.repo / "fake-scanner"
        self.write("fake-scanner", "#!/usr/bin/env python3\nimport sys\n"
                   "print(" + repr(self.token()) + ")\n"
                   "print(" + repr(self.token()) + ", file=sys.stderr)\nsys.exit(2)\n")
        scanner.chmod(0o700)
        result = self.run_gate("--scanner", str(scanner))
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("no valid JSON report", result.stdout)

    def test_real_pipeline_rejects_unredacted_report(self):
        scanner = self.repo / "fake-scanner"
        self.write("fake-scanner", "#!/usr/bin/env python3\nimport sys,json\nfrom pathlib import Path\n"
                   "Path(sys.argv[sys.argv.index('--report-path')+1]).write_text(json.dumps(["
                   "{'RuleID':'github-pat','Secret':" + repr(self.token()) + "}]))\nsys.exit(1)\n")
        scanner.chmod(0o700)
        result = self.run_gate("--scanner", str(scanner))
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("missing full secret redaction", result.stdout)

    def test_ref_and_content_changes_fail_closed(self):
        for mutation in ("ref", "content"):
            with self.subTest(mutation=mutation):
                delivered = []
                def interrupted_scan(*args):
                    if not delivered:
                        if mutation == "ref":
                            self.git("branch", "changed-during-scan")
                        else:
                            self.write("safe.txt", "changed during scan\n")
                        delivered.append(mutation)
                    return []
                with patch.object(safety, "scan", side_effect=interrupted_scan) as scanner:
                    with self.assertRaisesRegex(safety.SafetyFailure, "changed during scan"):
                        safety.audit(self.repo, "gitleaks")
                    self.assertEqual(scanner.call_count, 2)
                    self.assertEqual(delivered, [mutation])

    def test_missing_candidate_fails_closed(self):
        (self.repo / "safe.txt").unlink()
        result = self.run_gate()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("candidate file absent", result.stdout)

    def test_unredacted_and_invalid_reports_fail(self):
        for status, report in [(0, [{}]), (1, []), (2, []), (0, {}),
                               (1, [{"RuleID": "github-pat", "Secret": self.token()}])]:
            with self.subTest(status=status):
                with self.assertRaises(safety.SafetyFailure):
                    safety.validate_report(status, report)


if __name__ == "__main__":
    unittest.main()
