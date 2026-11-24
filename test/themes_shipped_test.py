"""Static controls for the shipped Themes gallery; never launches the app.

Two properties are pinned from source, because neither is visible in a build:

1. Themes has no build-time gate. A stale flag would silently hide the gallery again.
2. The catalog is fetched only when the user opens the gallery. The app has exactly one
   fetch entry point, and its only callers are the gallery opener and the packaged
   loopback verification. Nothing on the launch path may reach it.
"""
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATE = re.compile(r"PathemThemesBeta|PATHEM_THEMES_BETA|betaEnabled")
FETCH = "SharedThemeCatalog.fetch("
REFRESH = "refreshSharedCatalog("
FUNCTION = re.compile(r"\bfunc\s+(\w+)")
# file -> the functions allowed to contain each call
FETCH_CALLERS = {
    "Sources/Pathem/CommunityThemeGalleryWindow.swift": {"refreshSharedCatalog"},
    "Sources/pathem-theme-catalog/main.swift": None,  # the maintainer CLI, not the app
}
REFRESH_CALLERS = {
    "Sources/Pathem/SettingsWindowController.swift": {"openCommunityThemes"},
    "Sources/Pathem/CommunityThemeGalleryWindow.swift": {"verifyPackagedInstallation"},
}
# test/e2e/run.sh names the retired key once, to assert it is absent; it is checked separately.
GATE_SCOPES = ["Sources", "scripts", "Packaging", "Makefile", "docs/themes"]


def call_sites(root, needle):
    """Return {(relative file, enclosing function)} for each call, skipping declarations."""
    found = set()
    for path in sorted((root / "Sources").rglob("*.swift")):
        enclosing = None
        for line in path.read_text().splitlines():
            code = line.split("//")[0]
            declared = FUNCTION.search(code)
            if declared:
                enclosing = declared.group(1)
                if declared.group(1) + "(" == needle:
                    continue
            if needle in code:
                found.add((path.relative_to(root).as_posix(), enclosing))
    return found


def violations(root, needle, allowed):
    return sorted(
        f"{file}:{function}" for file, function in call_sites(root, needle)
        if file not in allowed or (allowed[file] is not None and function not in allowed[file])
    )


def gate_mentions(root):
    hits = []
    for scope in GATE_SCOPES:
        base = root / scope
        files = [base] if base.is_file() else sorted(p for p in base.rglob("*") if p.is_file())
        for path in files:
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            if GATE.search(text):
                hits.append(path.relative_to(root).as_posix())
    return hits


class ThemesShipped(unittest.TestCase):
    def test_no_build_time_gate_remains(self):
        self.assertEqual(gate_mentions(ROOT), [])

    def test_catalog_fetch_has_one_app_entry_point(self):
        self.assertEqual(violations(ROOT, FETCH, FETCH_CALLERS), [])
        self.assertIn(
            ("Sources/Pathem/CommunityThemeGalleryWindow.swift", "refreshSharedCatalog"),
            call_sites(ROOT, FETCH))

    def test_catalog_refresh_runs_only_on_explicit_user_action(self):
        self.assertEqual(violations(ROOT, REFRESH, REFRESH_CALLERS), [])
        self.assertIn(
            ("Sources/Pathem/SettingsWindowController.swift", "openCommunityThemes"),
            call_sites(ROOT, REFRESH))

    def test_gallery_opener_is_reached_only_from_its_button(self):
        source = (ROOT / "Sources/Pathem/SettingsWindowController.swift").read_text()
        self.assertEqual(source.count("openCommunityThemes"), 2)  # the selector and the method
        self.assertIn("action: #selector(openCommunityThemes)", source)

    def test_packaged_run_always_exercises_themes(self):
        runner = (ROOT / "test/e2e/run.sh").read_text()
        for script in ("test/shared_theme_catalog_e2e.py", "test/theme_admin_e2e.py"):
            self.assertEqual(runner.count(script), 1, script)
        self.assertIn('assert "no Themes build flag in the bundle" test -z "$themes_flag"', runner)
        self.assertEqual(len(GATE.findall(runner)), 1)  # only the absence check reads the key
        self.assertNotIn("PATHEM_THEMES_BETA", runner)
        makefile = (ROOT / "Makefile").read_text()
        ci = makefile[makefile.index("\nci:"):makefile.index("\napp:")]
        self.assertEqual(ci.count("test/e2e/run.sh --packaged"), 1)


class Controls(unittest.TestCase):
    """The checks above must be able to fail: plant each defect in a scratch tree."""

    def tree(self, files):
        folder = tempfile.TemporaryDirectory(prefix="pathem-themes-control-")
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        for name, text in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(text)
        for scope in GATE_SCOPES:
            if not (root / scope).exists():
                (root / scope).mkdir(parents=True)
        return root

    def test_launch_time_refresh_is_reported(self):
        root = self.tree({
            "Sources/Pathem/PathemApp.swift":
                "func applicationDidFinishLaunching() {\n"
                "    try await CommunityThemeGalleryWindow.refreshSharedCatalog(endpoint, at: url)\n"
                "}\n",
        })
        self.assertEqual(
            violations(root, REFRESH, REFRESH_CALLERS),
            ["Sources/Pathem/PathemApp.swift:applicationDidFinishLaunching"])

    def test_second_fetch_entry_point_is_reported(self):
        root = self.tree({
            "Sources/Pathem/CommunityThemeGalleryWindow.swift":
                "static func refreshSharedCatalog(_ endpoint: String) {\n"
                "    _ = try await SharedThemeCatalog.fetch(endpoint)\n"
                "}\n"
                "func prewarm() {\n"
                "    _ = try await SharedThemeCatalog.fetch(endpoint)\n"
                "}\n",
        })
        self.assertEqual(
            violations(root, FETCH, FETCH_CALLERS),
            ["Sources/Pathem/CommunityThemeGalleryWindow.swift:prewarm"])

    def test_comment_and_declaration_are_not_calls(self):
        root = self.tree({
            "Sources/Pathem/Notes.swift":
                "// refreshSharedCatalog(endpoint) runs when the gallery opens\n"
                "static func refreshSharedCatalog(_ endpoint: String) {}\n",
        })
        self.assertEqual(call_sites(root, REFRESH), set())

    def test_stale_flag_is_reported(self):
        root = self.tree({"scripts/package.sh": 'Add :PathemThemesBeta bool true\n'})
        self.assertEqual(gate_mentions(root), ["scripts/package.sh"])


if __name__ == "__main__":
    unittest.main()
