"""Tests for Integrations/commandem/commandem-pathem (no app launch: --print only)."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[1] / "Integrations/commandem/commandem-pathem"


class CommandemPathemTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="commandem-pathem-")
        base = Path(self.tmp.name).resolve()
        self.alpha = base / "Alpha"
        self.alpha_wb = base / "worktrees" / "alpha-claude"
        self.beta = base / "Beta Project"
        for d in (self.alpha, self.alpha_wb, self.beta):
            (d / "src").mkdir(parents=True)
            (d / "src" / "main.swift").write_text("print(1)\n")
        rows = [
            {"Name": "Alpha", "WorkingDir": str(self.alpha)},
            {"Name": "alpha-claude", "WorkingDir": str(self.alpha_wb)},
            {"Name": "Beta Project", "WorkingDir": str(self.beta)},
        ]
        self.fake = base / "fake-commandem"
        self.fake.write_text(
            "#!/bin/sh\n[ \"$1\" = projects ] || exit 9\ncat <<'J'\n"
            + json.dumps({"projects": rows}) + "\nJ\n")
        self.fake.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_plugin(self, *args, cwd=None, cli="/fake/pathem-cli"):
        env = dict(os.environ, COMMANDEM_BIN=str(self.fake), PATHEM_CLI=cli)
        return subprocess.run([sys.executable, str(PLUGIN), *args, "--print"], cwd=cwd,
                              env=env, capture_output=True, text=True)

    def test_project_root_opens(self):
        out = self.run_plugin("Alpha")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), f"/fake/pathem-cli open {self.alpha}")

    def test_file_reveals_and_folder_opens(self):
        self.assertIn(f"reveal {self.alpha}/src/main.swift",
                      self.run_plugin("Alpha", "src/main.swift").stdout)
        self.assertIn(f"open {self.alpha}/src", self.run_plugin("Alpha", "src").stdout)

    def test_matching_exact_prefix_substring_and_ambiguity(self):
        self.assertIn(str(self.alpha), self.run_plugin("alpha").stdout)  # exact wins over prefix
        self.assertIn("Beta Project", self.run_plugin("bet").stdout)  # unique prefix
        self.assertIn(str(self.alpha_wb), self.run_plugin("claude").stdout)  # unique substring
        ambiguous = self.run_plugin("a")
        self.assertNotEqual(ambiguous.returncode, 0)
        self.assertIn("matches several projects", ambiguous.stderr)
        missing = self.run_plugin("zzz")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("no project matches", missing.stderr)

    def test_current_directory_picks_the_deepest_project(self):
        out = self.run_plugin(cwd=self.alpha_wb / "src")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(f"open {self.alpha_wb}", out.stdout)

    def test_paths_may_not_leave_the_project_and_must_exist(self):
        escape = self.run_plugin("Alpha", "../Beta Project")
        self.assertNotEqual(escape.returncode, 0)
        self.assertIn("leaves the project", escape.stderr)
        missing = self.run_plugin("Alpha", "src/nope.swift")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("no such file", missing.stderr)

    def test_preview_needs_a_file(self):
        self.assertIn(f"preview {self.alpha}/src/main.swift",
                      self.run_plugin("Alpha", "--preview", "src/main.swift").stdout)
        self.assertNotEqual(self.run_plugin("Alpha", "--preview", "src").returncode, 0)

    def test_changed_reveals_the_newest_change_and_skips_deleted_files(self):
        root = self.beta
        git = lambda *a: subprocess.run(["git", "-C", str(root), *a], capture_output=True)
        git("init", "-q")
        git("-c", "user.email=t@example.invalid", "-c", "user.name=t", "add", "-A")
        git("-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-qm", "init")
        (root / "src" / "main.swift").write_text("print(2)\n")
        time.sleep(0.05)
        (root / "new file.txt").write_text("x\n")
        os.utime(root / "src" / "main.swift", (1, 1))  # older
        out = self.run_plugin("Beta", "--changed")
        self.assertEqual(out.returncode, 0, out.stderr)
        lines = out.stdout.strip().splitlines()
        self.assertEqual(lines[-1], f"/fake/pathem-cli reveal '{root}/new file.txt'")
        self.assertIn("src/main.swift", lines[0])
        clean = self.run_plugin("Alpha", "--changed")
        self.assertNotEqual(clean.returncode, 0)  # not a git repository

    def test_url_fallback_encodes_the_path(self):
        out = self.run_plugin("Beta", cli="none")
        self.assertIn("open 'pathem://open?path=", out.stdout)
        self.assertIn("Beta%20Project", out.stdout)


if __name__ == "__main__":
    unittest.main()
