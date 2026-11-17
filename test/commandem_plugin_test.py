"""Tests for Integrations/commandem/commandem-pathem (no app launch: --print only)."""
import json
import os
import subprocess
import sys
import tempfile
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
        self.assertEqual(out.stdout.strip(), f"/fake/pathem-cli {self.alpha}")

    def test_file_reveals_and_folder_opens(self):
        # The CLI chooses open vs reveal itself, so the plugin passes only the absolute path.
        self.assertEqual(self.run_plugin("Alpha", "src/main.swift").stdout.strip(),
                         f"/fake/pathem-cli {self.alpha}/src/main.swift")
        self.assertEqual(self.run_plugin("Alpha", "src").stdout.strip(),
                         f"/fake/pathem-cli {self.alpha}/src")
        # Without the CLI the URL fallback still picks the verb.
        self.assertIn("pathem://reveal?path=", self.run_plugin(
            "Alpha", "src/main.swift", cli="none").stdout)
        self.assertIn("pathem://open?path=", self.run_plugin("Alpha", "src", cli="none").stdout)

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
        self.assertIn(f"/fake/pathem-cli {self.alpha_wb}", out.stdout)

    def test_paths_may_not_leave_the_project_and_must_exist(self):
        escape = self.run_plugin("Alpha", "../Beta Project")
        self.assertNotEqual(escape.returncode, 0)
        self.assertIn("leaves the project", escape.stderr)
        missing = self.run_plugin("Alpha", "src/nope.swift")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("no such file", missing.stderr)

    def test_preview_needs_a_file(self):
        self.assertIn(f"/fake/pathem-cli preview {self.alpha}/src/main.swift",
                      self.run_plugin("Alpha", "--preview", "src/main.swift").stdout)
        self.assertNotEqual(self.run_plugin("Alpha", "--preview", "src").returncode, 0)

    def test_changed_delegates_to_the_cli_with_the_project_root(self):
        out = self.run_plugin("Beta", "--changed")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), f"/fake/pathem-cli changed '{self.beta}'")
        self.assertNotEqual(self.run_plugin("Beta", "src", "--changed").returncode, 0)
        # No CLI, no git logic of its own: it says so rather than guessing.
        nocli = self.run_plugin("Beta", "--changed", cli="none")
        self.assertNotEqual(nocli.returncode, 0)
        self.assertIn("pathem-cli", nocli.stderr)

    def test_real_run_passes_arguments_to_the_cli(self):
        log = Path(self.tmp.name) / "args.txt"
        cli = Path(self.tmp.name) / "fake-cli"
        cli.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{log}"\n')
        cli.chmod(0o755)
        env = dict(os.environ, COMMANDEM_BIN=str(self.fake), PATHEM_CLI=str(cli))
        done = subprocess.run([sys.executable, str(PLUGIN), "Beta", "src"], env=env,
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(log.read_text().split("\n")[0], f"{self.beta}/src")

    def test_url_fallback_encodes_the_path(self):
        out = self.run_plugin("Beta", cli="none")
        self.assertIn("open 'pathem://open?path=", out.stdout)
        self.assertIn("Beta%20Project", out.stdout)


if __name__ == "__main__":
    unittest.main()
