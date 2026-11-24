"""Community themes page: hostile catalog input, real image conversion, and determinism.

The conversions run the real sips and cwebp on real files in temp folders. The catalog is
treated as untrusted throughout, so most cases here are attacks that must fail or be inert.
"""

import base64
import copy
from html.parser import HTMLParser
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("site_themes", ROOT / "scripts/build_site_themes.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

try:
    builder.tool("sips"), builder.tool("cwebp")
    HAVE_TOOLS = True
except RuntimeError:
    HAVE_TOOLS = False


def png(width=48, height=32, seed=0):
    """A small real PNG, written by hand so the test needs no image library."""
    rows = b"".join(b"\x00" + bytes(value for x in range(width) for value in ((x * 5 + seed) % 256, (y * 7) % 256, (x + y + seed) % 256)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def sips_convert(data, kind, *properties):
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "in.png"
        target = Path(folder) / f"out.{kind}"
        source.write_bytes(data)
        subprocess.run([builder.tool("sips"), "-s", "format", kind, *properties, str(source), "--out", str(target)], check=True, capture_output=True)
        return target.read_bytes()


def package(**changes):
    value = {"schemaVersion": 2, "name": "Test", "appearance": "dark", "accent": "#D4334E", "background": "#1B1114"}
    value.update(changes)
    return base64.b64encode(json.dumps(value).encode()).decode()


def listing(screenshots=None, **changes):
    value = {
        "id": "test-theme",
        "version": 1,
        "title": "Test Theme",
        "summary": "A theme for tests.",
        "creator": "Tester",
        "license": "CC0-1.0",
        "source": "Original",
        "tags": ["dark", "test"],
        "package": package(),
        "screenshots": [base64.b64encode(data).decode() for data in (screenshots or [png()])],
    }
    value.update(changes)
    return value


def catalog(*listings):
    return {"schemaVersion": 1, "themes": list(listings) or [listing()]}


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.attributes = []
        self.text = []
        self.elements = []  # (tag, attributes, open ancestor tags)
        self.open = []
        self.labels = {}  # for= id -> visible label text
        self.label = None
        self.legends = []
        self.feed(text)
        self.close()

    def handle_starttag(self, tag, attributes):
        self.tags.append(tag)
        self.attributes += [(tag, key, value) for key, value in attributes]
        self.elements.append((tag, dict(attributes), tuple(self.open)))
        if tag == "label":
            self.labels[dict(attributes).get("for")] = ""
            self.label = dict(attributes).get("for")
        if tag not in ("meta", "link", "img", "input", "rect"):
            self.open.append(tag)

    def handle_endtag(self, tag):
        if tag == "label":
            self.label = None
        if tag in self.open:
            while self.open.pop() != tag:
                pass

    def handle_data(self, data):
        self.text.append(data)
        if self.label is not None:
            self.labels[self.label] += data
        if self.open and self.open[-1] == "legend":
            self.legends.append(data)

    def find(self, tag, **wanted):
        """Attributes of every <tag> whose attributes include the wanted ones."""
        return [found for name, found, _ in self.elements if name == tag and all(found.get(key.rstrip("_")) == value for key, value in wanted.items())]

    def ancestors(self, tag, **wanted):
        return next(inside for name, found, inside in self.elements if name == tag and all(found.get(key) == value for key, value in wanted.items()))


def scratch_root():
    """A temp site root holding only the stylesheet the page links."""
    folder = tempfile.TemporaryDirectory(prefix="pathem-themes-test-")
    target = Path(folder.name) / builder.STYLESHEET
    target.parent.mkdir(parents=True)
    shutil.copy(ROOT / builder.STYLESHEET, target)
    return folder


def build(data, root, **options):
    return builder.build(json.dumps(data).encode(), "test.json", root=Path(root), **options)


class ValidationTests(unittest.TestCase):
    """No image tools needed: validation runs before any conversion."""

    def rejects(self, pattern, *listings, **top):
        data = catalog(*listings)
        data.update(top)
        with self.assertRaisesRegex(builder.CatalogError, pattern):
            builder.validate(data)

    def test_good_listing_passes(self):
        (checked,) = builder.validate(catalog())
        self.assertEqual((checked["id"], checked["accent"], checked["appearance"]), ("test-theme", "#D4334E", "dark"))

    def test_bad_ids_are_rejected(self):
        for bad in ["../etc", "Upper", "", "a" * 65, "has space", "a/b", "a.b", 'x"y', "<b>", "é", 7, None]:
            with self.subTest(id=bad):
                self.rejects("id must be", listing(id=bad))
        self.rejects("duplicate id", listing(), listing())

    def test_bad_colors_are_rejected(self):
        for bad in ["red", "#12345", "#12345G", "#1234567", '#fff" onload="x', "D4334E", "url(x)", 5, None, ["#000000"]]:
            for key in ("accent", "background"):
                with self.subTest(color=bad, key=key):
                    self.rejects("not a #RRGGBB color", listing(package=package(**{key: bad})))

    def test_empty_color_means_system(self):
        (checked,) = builder.validate(catalog(listing(package=package(background="", appearance="system"))))
        self.assertIsNone(checked["background"])

    def test_bad_package_and_appearance_are_rejected(self):
        self.rejects("appearance", listing(package=package(appearance='dark" class="x')))
        self.rejects("invalid base64", listing(package="not base64!"))
        self.rejects("not JSON", listing(package=base64.b64encode(b"{").decode()))
        self.rejects("not an object", listing(package=base64.b64encode(b"[]").decode()))

    def test_bad_text_is_rejected(self):
        self.rejects("longer than 80", listing(title="x" * 81))
        self.rejects("longer than 600", listing(summary="x" * 601))
        self.rejects("control", listing(title="a\x00b"))
        self.rejects("control", listing(summary="line\nbreak"))
        self.rejects("control", listing(creator="evil‮gnp.exe"))
        self.rejects("whitespace", listing(title=" padded"))
        self.rejects("non-empty string", listing(title=""))
        self.rejects("non-empty string", listing(license=None))
        self.rejects("non-empty string", listing(tags=[["nested"]]))
        self.rejects("at most 8", listing(tags=["t"] * 9))
        self.rejects("positive integer", listing(version=True))
        self.rejects("positive integer", listing(version="1"))

    def test_bad_screenshots_are_rejected(self):
        svg = b'<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>'
        gif = b"GIF89a" + b"\x00" * 32
        self.rejects("not PNG, JPEG or HEIC", listing(screenshots=[svg]))
        self.rejects("not PNG, JPEG or HEIC", listing(screenshots=[gif]))
        self.rejects("one to three", listing(screenshots=[png()] * 4))
        self.rejects("one to three", listing(screenshots=[]) | {"screenshots": []})
        self.rejects("size limit", listing(screenshots=[b"\x89PNG\r\n\x1a\n" + b"0" * builder.MAX_SCREENSHOT_BYTES]))

    def test_bad_catalog_shape_is_rejected(self):
        self.rejects("schemaVersion 1", schemaVersion=2)
        with self.assertRaises(builder.CatalogError):
            builder.validate([])
        with self.assertRaises(builder.CatalogError):
            builder.validate({"schemaVersion": 1, "themes": ["x"]})


@unittest.skipUnless(HAVE_TOOLS, "sips and cwebp are needed to convert screenshots")
class BuildTests(unittest.TestCase):
    def test_malicious_text_is_escaped(self):
        title = '<script>alert(1)</script>"\'><img src=x onerror=alert(2)>'
        summary = '</p></article><script src="https://evil.example/x.js"></script> " onmouseover="x" \' & <style>*{display:none}</style>'
        hostile = listing(title=title, summary=summary, creator='<a href="javascript:alert(3)">me</a>', license="</dd><script>1</script>", source="javascript:alert(4)", tags=['"><svg onload=alert(5)>'])
        with scratch_root() as root:
            files, _ = build(catalog(hostile), root)
        text = files[builder.PAGE].decode()
        page = Page(text)
        self.assertNotIn("script", page.tags)
        self.assertNotIn("style", page.tags)
        self.assertEqual([entry for entry in page.attributes if entry[1].startswith("on") or entry[1] == "style"], [])
        # The only links and sources are the fixed ones and the generated image names.
        for tag, key, value in page.attributes:
            if key in ("href", "src", "content") and (key != "content" or value.startswith("http")):
                self.assertRegex(value, r"^(#main-content|/[a-z0-9/._#?=-]*|https://(pathem\.app|github\.com/Scarcrux/Pathem)[a-z0-9/.?=-]*)$", (tag, key))
        self.assertEqual(page.tags.count("img"), 3)  # two logos and one screenshot, none injected
        # The text survives as text: what the reader sees is exactly what was submitted.
        shown = "".join(page.text)
        for value in (title, summary, hostile["creator"], hostile["license"], hostile["source"], hostile["tags"][0]):
            self.assertIn(value, shown)
        alts = [value for tag, key, value in page.attributes if tag == "img" and key == "alt"]
        self.assertIn(f"{title} theme in Pathem. {summary}", alts)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", text)

    def test_png_jpeg_and_heic_all_become_webp(self):
        source = png(96, 64)
        inputs = {"png": source, "jpeg": sips_convert(source, "jpeg"), "heic": sips_convert(source, "heic")}
        for kind, data in inputs.items():
            with self.subTest(kind=kind):
                self.assertEqual(builder.image_format(data), kind)
                webp, width, height, mode = builder.to_webp(kind, data)
                self.assertEqual((webp[:4], webp[8:12]), (b"RIFF", b"WEBP"))
                self.assertEqual((width, height), (96, 64))
                self.assertIn(mode, ("lossless", "q90"))
        with scratch_root() as root:
            files, record = build(catalog(listing(screenshots=list(inputs.values()))), root)
        self.assertEqual([image["input"] for image in record["images"]], ["png", "jpeg", "heic"])
        images = {name: data for name, data in files.items() if name.startswith(builder.IMAGE_DIR)}
        self.assertEqual(len(images), 3)
        for name, data in images.items():
            self.assertEqual(Path(name).name, hashlib.sha256(data).hexdigest()[:20] + ".webp")
            self.assertIn(f'src="/themes/img/{Path(name).name}"', files[builder.PAGE].decode())

    def test_metadata_is_stripped(self):
        marker = "PRIVATE-MARKER-7f3a"
        tagged = sips_convert(png(), "jpeg", "-s", "description", marker, "-s", "copyright", marker)
        self.assertIn(marker.encode(), tagged)  # the control: the input really carries it
        webp, _, _, _ = builder.to_webp("jpeg", tagged)
        self.assertNotIn(marker.encode(), webp)
        for chunk in (b"EXIF", b"XMP ", b"ICCP"):
            self.assertNotIn(chunk, webp)

    def test_oversized_and_undecodable_images_are_rejected(self):
        with self.assertRaisesRegex(builder.CatalogError, "outside the size limit"):
            builder.to_webp("png", png(builder.MAX_PIXELS_PER_SIDE + 1, 2))
        with self.assertRaises(builder.CatalogError):
            builder.to_webp("png", b"\x89PNG\r\n\x1a\n" + b"garbage" * 20)

    def test_build_is_deterministic_and_check_sees_drift(self):
        data = catalog(listing(), listing(id="second", title="Second", screenshots=[png(seed=9), png(seed=40)], package=package(appearance="light")))
        with scratch_root() as root:
            first, record = build(data, root, updated="2026-01-02")
            second, _ = build(copy.deepcopy(data), root, updated="2026-01-02")
            self.assertEqual(first, second)
            builder.write(first, Path(root))
            self.assertEqual(builder.differences(first, Path(root)), [])
            self.assertEqual(builder.audit(Path(root)), [])
            # A rebuild of unchanged input keeps the recorded date, so nothing changes on disk.
            third, again = build(data, root)
            self.assertEqual(again["updated"], "2026-01-02")
            self.assertEqual(third, first)
            # Red controls: every kind of drift is reported.
            image = Path(root) / builder.IMAGE_DIR / record["images"][0]["file"]
            original = image.read_bytes()
            image.write_bytes(original + b"x")
            self.assertTrue(any("content hash" in problem for problem in builder.audit(Path(root))))
            self.assertIn(f"{builder.IMAGE_DIR}/{image.name}", builder.differences(first, Path(root)))
            image.write_bytes(original)
            stray = Path(root) / builder.IMAGE_DIR / "stray.webp"
            stray.write_bytes(b"x")
            self.assertTrue(any("stale" in problem for problem in builder.differences(first, Path(root))))
            self.assertTrue(any("not referenced" in problem for problem in builder.audit(Path(root))))
            builder.write(first, Path(root))
            self.assertFalse(stray.exists())
            page = Path(root) / builder.PAGE
            page.write_text(page.read_text().replace("Second", "Changed"))
            self.assertTrue(any("build record" in problem for problem in builder.audit(Path(root))))
            # A different catalog moves the date.
            _, changed = build(catalog(listing(title="Renamed")), root)
            self.assertNotEqual(changed["updated"], "2026-01-02")

    def test_page_shape(self):
        two = listing(id="second", title="Second", screenshots=[png(seed=9), png(seed=40)], package=package(appearance="light", background=""))
        with scratch_root() as root:
            files, _ = build(catalog(listing(), two), root)
        text = files[builder.PAGE].decode()
        page = Page(text)
        self.assertEqual(page.tags.count("h1"), 1)
        self.assertEqual(page.tags.count("h2"), 2)
        self.assertEqual([entry for entry in page.attributes if entry[0] == "img" and entry[1] == "alt" and not entry[2]], [])
        self.assertEqual(page.tags.count("img"), sum(1 for entry in page.attributes if entry[0] == "img" and entry[1] == "alt"))
        self.assertIn(("rect", "fill", "#D4334E"), page.attributes)
        self.assertIn("Second, screenshot 2 of 2", [entry[2] for entry in page.attributes])
        self.assertIn(">System<", text)

    def filter_page(self, *appearances):
        themes = [listing(id=f"theme-{index}", title=f"Theme {index}", screenshots=[png(seed=index)], package=package(appearance=appearance)) for index, appearance in enumerate(appearances)]
        with scratch_root() as root:
            files, _ = build(catalog(*themes), root)
        return Page(files[builder.PAGE].decode())

    def shown_by(self, page, choice):
        """How many cards the stylesheet leaves visible for a filter choice, read from data-appearance."""
        hidden = {"all": set(), "light": {"dark"}, "dark": {"light"}}[choice]
        return sum(1 for card in page.find("li", class_="theme") if card["data-appearance"] not in hidden)

    def test_cards_carry_the_package_appearance_not_the_tags(self):
        # The tags say "dark" on every test listing; only the package decides.
        page = self.filter_page("light", "dark", "dark", "system")
        self.assertEqual([card["data-appearance"] for card in page.find("li", class_="theme")], ["light", "dark", "dark", "system"])

    def test_filter_is_three_labeled_radios_with_counts(self):
        page = self.filter_page("light", "dark", "dark", "light", "light")
        radios = page.find("input", type="radio")
        self.assertEqual([radio["id"] for radio in radios], ["show-all", "show-light", "show-dark"])
        self.assertEqual({radio["name"] for radio in radios}, {"appearance"})
        self.assertEqual([radio["id"] for radio in radios if "checked" in radio], ["show-all"])
        for radio in radios:
            self.assertIn("fieldset", page.ancestors("input", id=radio["id"]))
        self.assertEqual(page.legends, ["Show"])
        self.assertEqual({key: " ".join(value.split()) for key, value in page.labels.items()}, {"show-all": "All 5 themes", "show-light": "Light 3 themes", "show-dark": "Dark 2 themes"})
        for choice, count in (("all", 5), ("light", 3), ("dark", 2)):
            self.assertEqual(self.shown_by(page, choice), count)
        # The radios sit before the gallery, inside the section the stylesheet's :has() rules match.
        order = [(tag, found.get("class")) for tag, found, _ in page.elements]
        self.assertLess(order.index(("fieldset", "filter")), order.index(("ul", "gallery")))
        self.assertIn("section", page.ancestors("fieldset", **{"class": "filter"}))

    def test_system_theme_counts_as_both_light_and_dark(self):
        page = self.filter_page("light", "dark", "system")
        labels = {key: " ".join(value.split()) for key, value in page.labels.items()}
        self.assertEqual(labels, {"show-all": "All 3 themes", "show-light": "Light 2 themes", "show-dark": "Dark 2 themes"})
        self.assertEqual((self.shown_by(page, "light"), self.shown_by(page, "dark")), (2, 2))

    def test_filter_is_left_out_when_it_could_not_narrow_anything(self):
        for appearances in (["dark"], ["dark", "dark"], ["light", "light"], ["system", "system"], ["light", "system"]):
            with self.subTest(appearances=appearances):
                page = self.filter_page(*appearances)
                self.assertEqual(page.find("input"), [])
                self.assertIn(f"{len(appearances)} theme", "".join(page.text))
        self.assertIn("1 theme ", " ".join("".join(self.filter_page("dark").text).split()) + " ")

    def test_stylesheet_hides_the_other_appearance_and_shows_focus(self):
        css = " ".join((ROOT / builder.STYLESHEET).read_text().split())
        self.assertIn('.published:has(#show-light:checked) .theme[data-appearance="dark"]', css)
        self.assertIn('.published:has(#show-dark:checked) .theme[data-appearance="light"]', css)
        self.assertNotIn('[data-appearance="system"]', css)  # a system theme is never hidden
        self.assertIn(".filter input:focus-visible + label", css)
        self.assertIn(".filter input:checked + label", css)
        # The radios stay focusable: hidden from sight, never display: none.
        rule = css[css.index(".filter input {") :].split("}")[0]
        self.assertNotIn("display", rule)
        self.assertNotIn("visibility", rule)

    def test_intro_punctuation_and_current_page_in_the_header(self):
        page = self.filter_page("light", "dark")
        shown = " ".join("".join(page.text).split())
        self.assertNotIn("….", shown)
        self.assertNotIn("...", shown)
        self.assertIn("click Themes… to open the gallery.", shown)
        header = [found for tag, found, inside in page.elements if tag == "a" and "header" in inside and "nav" in inside]
        self.assertEqual([link["href"] for link in header if link.get("aria-current") == "page"], ["/themes/"])
        self.assertEqual([link["href"] for link in header if "ghost" in (link.get("class") or "")], [])
        self.assertIn("/", [link["href"] for link in header])
        css = " ".join((ROOT / builder.STYLESHEET).read_text().split())
        self.assertIn(".nav-links a[aria-current]", css)


class CommittedOutputTests(unittest.TestCase):
    """The page in the repository, checked against itself with no catalog and no tools."""

    def test_committed_page_matches_its_record(self):
        self.assertEqual(builder.audit(), [])

    def test_record_is_public_safe_and_dated_in_the_sitemap(self):
        record = builder.read_record()
        self.assertNotIn("/Users/", json.dumps(record))
        self.assertTrue(record["source"].startswith("https://") or "/" not in record["source"])
        sitemap = ET.fromstring((ROOT / "site/sitemap.xml").read_text())
        dates = {url[0].text: url[1].text for url in sitemap}
        self.assertEqual(dates.get(f"{builder.BASE}/themes/"), record["updated"])

    def test_committed_page_has_no_inline_style_or_script(self):
        page = Page((ROOT / builder.PAGE).read_text())
        self.assertNotIn("script", page.tags)
        self.assertNotIn("style", page.tags)
        self.assertEqual([entry for entry in page.attributes if entry[1] == "style" or entry[1].startswith("on")], [])
        headers = (ROOT / "site/_headers").read_text()
        self.assertIn("img-src 'self'", headers)
        self.assertNotIn("unsafe-inline", headers)


if __name__ == "__main__":
    unittest.main()
