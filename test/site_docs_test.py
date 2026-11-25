"""Real static-output, source-anchor and discriminating negative checks for website guides."""

import copy
from html.parser import HTMLParser
import importlib.util
import json
from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("site_docs", ROOT / "scripts/build_site_docs.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.links = []
        self.h1s = 0
        self.images_without_alt = 0
        self.lang = None
        self.feed(text)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "h1":
            self.h1s += 1
        if tag == "html":
            self.lang = attrs.get("lang")
        if tag == "img" and "alt" not in attrs:
            self.images_without_alt += 1
        for key in ["href", "src", "poster"]:
            if attrs.get(key):
                self.links.append(attrs[key])


def link_errors(pages, root=ROOT / "site"):
    errors = []
    for name, page in pages.items():
        if len(page.ids) != len(set(page.ids)):
            errors.append(f"duplicate id: {name}")
        for value in page.links:
            url = urlsplit(value)
            if url.scheme or url.netloc:
                continue
            target = (root / unquote(url.path).lstrip("/")) if url.path.startswith("/") else (root / name).parent / unquote(url.path)
            if not url.path:
                target = root / name
            if target.is_dir():
                target /= "index.html"
            target = target.resolve()
            if not target.is_relative_to(root.resolve()) or not target.is_file():
                errors.append(f"missing target: {name}: {value}")
                continue
            relative = str(target.relative_to(root))
            if url.fragment and relative in pages and unquote(url.fragment) not in pages[relative].ids:
                errors.append(f"missing anchor: {name}: {value}")
    return errors


class SiteDocsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(builder.CONTENT.read_text())
        cls.generated = builder.build(cls.data)
        cls.pages = {str(path.relative_to(ROOT / "site")): Page(path.read_text()) for path in (ROOT / "site").rglob("*.html")}

    def test_generated_output_is_current(self):
        for name, expected in self.generated.items():
            with self.subTest(name=name):
                self.assertEqual((ROOT / name).read_text(), expected)

    def test_every_local_page_link_and_anchor_resolves(self):
        self.assertEqual(link_errors(self.pages), [])

    def test_link_instrument_rejects_missing_file_and_anchor(self):
        pages = dict(self.pages)
        pages["docs/index.html"] = Page((ROOT / "site/docs/index.html").read_text() + '<a href="/docs/not-a-guide/">Bad</a><a href="/docs/#not-an-anchor">Bad anchor</a>')
        errors = link_errors(pages)
        self.assertTrue(any("missing target" in error for error in errors))
        self.assertTrue(any("missing anchor" in error for error in errors))

    def test_duplicate_id_control_is_rejected(self):
        pages = dict(self.pages)
        pages["docs/index.html"] = Page('<main id="same"></main><aside id="same"></aside>')
        self.assertTrue(any("duplicate id" in error for error in link_errors(pages)))

    def test_accessible_static_basics_without_javascript(self):
        for name, page in self.pages.items():
            if not name.startswith("docs/"):
                continue
            with self.subTest(name=name):
                self.assertEqual(page.h1s, 1)
                self.assertEqual(page.lang, "en")
                self.assertEqual(page.images_without_alt, 0)
                self.assertIn("main-content", page.ids)
                self.assertIn("#main-content", page.links)

    def test_evidence_contract_rejects_source_drift(self):
        data = copy.deepcopy(self.data)
        data["guides"][0]["sources"][0]["needles"].append("THIS_SOURCE_ANCHOR_MUST_NOT_EXIST")
        with self.assertRaisesRegex(ValueError, "Source contract changed"):
            builder.build(data)

    def test_schema_rejects_duplicate_guides_and_missing_steps(self):
        data = copy.deepcopy(self.data)
        data["guides"].append(data["guides"][0])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            builder.build(data)
        data = copy.deepcopy(self.data)
        for section in data["guides"][0]["sections"]:
            section.pop("steps", None)
        with self.assertRaisesRegex(ValueError, "actionable steps"):
            builder.build(data)

    def test_inline_content_is_escaped(self):
        self.assertEqual(builder.inline('<script>bad()</script>'), '&lt;script&gt;bad()&lt;/script&gt;')
        self.assertEqual(builder.inline('Use `Command-K`.'), 'Use <code>Command-K</code>.')
        self.assertNotIn('href="javascript:', builder.inline('[bad](javascript:alert(1))'))

    def test_all_guides_in_search_and_sitemap(self):
        index = json.loads(self.generated["site/docs/search-index.json"])
        urls = {entry["url"] for entry in index}
        expected = {f'/docs/{guide["id"]}/' for guide in self.data["guides"]}
        self.assertEqual(urls, expected)
        sitemap = ET.fromstring(self.generated["site/sitemap.xml"])
        locations = {node.text for node in sitemap.iter() if node.tag.endswith("}loc")}
        self.assertTrue({builder.BASE + path for path in expected}.issubset(locations))
        for entry in index:
            self.assertNotIn("Sources/Pathem", entry["text"])

    def test_settings_window_has_one_name(self):
        # The window and app menu item are "Settings"; guides and the palette command must agree.
        index = json.loads(self.generated["site/docs/search-index.json"])
        stale = [entry["url"] for entry in index if "Preferences" in entry["text"]]
        self.assertEqual(stale, [], "guide prose still calls the Settings window Preferences")
        mismatched = []
        catalogs = sorted((ROOT / "Sources/Pathem/Resources").glob("*.lproj/Localizable.strings"))
        self.assertEqual(len(catalogs), 12)
        for catalog in catalogs:
            pairs = dict(re.findall(r'^"([^"]+)" = "(.*)";$', catalog.read_text(encoding="utf-8"), re.M))
            if pairs["bvc.cmd.preferences"] != pairs["settings.title"] + "…":
                mismatched.append(f'{catalog.parent.name}: {pairs["bvc.cmd.preferences"]}')
        self.assertEqual(mismatched, [], "palette command name differs from the Settings window title")


if __name__ == "__main__":
    unittest.main()
