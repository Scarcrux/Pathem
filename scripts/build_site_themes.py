#!/usr/bin/env python3
"""Build the public Community themes gallery page from the theme catalog.

The catalog is untrusted, user-submitted content. Every field is validated before use,
every text is HTML-escaped, and every screenshot is decoded to pixels and re-encoded as
WebP, so no submitted bytes or metadata are ever served as they arrived.

Usage:
    python3 scripts/build_site_themes.py                 # build from the live catalog
    python3 scripts/build_site_themes.py catalog.json    # build from a local snapshot
    python3 scripts/build_site_themes.py [source] --check  # fail if the output would differ

Image format (measured 2026-11-24 on the 13-theme seed catalog): each screenshot is encoded
twice, as lossless WebP and as WebP at quality 90, and the smaller file is kept (lossless
wins a tie because it is exact). Flat UI screenshots that arrive as PNG come out about 22%
smaller lossless than at q90 (about 48 KB against 61 KB at 1200x758). Screenshots that
arrive already lossy (JPEG, HEIC) carry compression noise that lossless WebP would
preserve at two to three times the size (108 KB against 42 KB), so they end up at q90.
"""

import argparse
import base64
import binascii
import concurrent.futures
import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unicodedata
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://pathem.app"
LIVE_CATALOG = "https://d3v2l0mmdgkblv.cloudfront.net/catalog.json"
PAGE = "site/themes/index.html"
IMAGE_DIR = "site/themes/img"
STYLESHEET = "site/assets/themes.css"
# Not served: records which catalog the committed page was built from, and how.
RECORD = "docs/website/themes-build.json"
SOCIAL_IMAGE = f"{BASE}/assets/social-card.png?v=3"
SRGB_PROFILE = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"

# Limits mirror the app's own (SharedThemeCatalog, CommunityThemeRevision.validate).
MAX_CATALOG_BYTES = 24 * 1024 * 1024
MAX_THEMES = 500
MAX_SCREENSHOT_BYTES = 2 * 1024 * 1024
MAX_PACKAGE_BYTES = 512 * 1024
MAX_PIXELS_PER_SIDE = 2400
ID_PATTERN = re.compile(r"[a-z0-9-]{1,64}")
HEX_PATTERN = re.compile(r"#[0-9A-Fa-f]{6}")
APPEARANCES = {"light": "Light", "dark": "Dark", "system": "Follows system"}
HEIC_BRANDS = {b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1"}
# Bidirectional controls can make text read differently from what it says.
BIDI_CONTROLS = set(range(0x202A, 0x202F)) | set(range(0x2066, 0x206A)) | {0x200E, 0x200F, 0x061C}


class CatalogError(ValueError):
    """The catalog, or one listing in it, is not acceptable for publishing."""


def esc(value):
    return html.escape(value, quote=True)


def text_field(listing, key, limit, where, optional=False):
    value = listing.get(key)
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value:
        raise CatalogError(f"{where}: {key} must be a non-empty string")
    if len(value.encode("utf-8")) > limit:
        raise CatalogError(f"{where}: {key} is longer than {limit} bytes")
    if value != value.strip():
        raise CatalogError(f"{where}: {key} has leading or trailing whitespace")
    for character in value:
        if unicodedata.category(character) in ("Cc", "Cs", "Co", "Cn") or ord(character) in BIDI_CONTROLS:
            raise CatalogError(f"{where}: {key} contains a control or unassigned character")
    return value


def decode_base64(value, limit, where):
    if not isinstance(value, str) or len(value) > limit * 4 // 3 + 8:
        raise CatalogError(f"{where}: not base64 text within the size limit")
    try:
        data = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise CatalogError(f"{where}: invalid base64") from None
    if not data or len(data) > limit:
        raise CatalogError(f"{where}: empty or over the size limit")
    return data


def color_field(package, key, where):
    value = package.get(key, "")
    if value == "":
        return None  # the theme leaves this color to the system
    if not isinstance(value, str) or not HEX_PATTERN.fullmatch(value):
        raise CatalogError(f"{where}: {key} is not a #RRGGBB color")
    return value.upper()


def image_format(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if len(data) > 12 and data[4:8] == b"ftyp" and data[8:12] in HEIC_BRANDS:
        return "heic"
    return None


def validate(catalog):
    """Return the listings as plain, checked values. Raises CatalogError on anything odd."""
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 1:
        raise CatalogError("catalog: expected an object with schemaVersion 1")
    themes = catalog.get("themes")
    if not isinstance(themes, list) or len(themes) > MAX_THEMES:
        raise CatalogError("catalog: themes must be a list within the size limit")
    seen = set()
    listings = []
    for position, listing in enumerate(themes):
        if not isinstance(listing, dict):
            raise CatalogError(f"theme {position}: not an object")
        identifier = listing.get("id")
        if not isinstance(identifier, str) or not ID_PATTERN.fullmatch(identifier):
            raise CatalogError(f"theme {position}: id must be 1 to 64 of a-z, 0-9 and hyphen")
        if identifier in seen:
            raise CatalogError(f"theme {identifier}: duplicate id")
        seen.add(identifier)
        where = f"theme {identifier}"
        version = listing.get("version")
        if type(version) is not int or not 0 < version < 2**31:
            raise CatalogError(f"{where}: version must be a positive integer")
        tags = listing.get("tags")
        if not isinstance(tags, list) or len(tags) > 8:
            raise CatalogError(f"{where}: tags must be a list of at most 8")
        package_bytes = decode_base64(listing.get("package"), MAX_PACKAGE_BYTES, f"{where}: package")
        try:
            package = json.loads(package_bytes)
        except (ValueError, RecursionError):
            raise CatalogError(f"{where}: package is not JSON") from None
        if not isinstance(package, dict):
            raise CatalogError(f"{where}: package is not an object")
        appearance = package.get("appearance")
        if not isinstance(appearance, str) or appearance not in APPEARANCES:
            raise CatalogError(f"{where}: appearance must be light, dark or system")
        screenshots = listing.get("screenshots")
        if not isinstance(screenshots, list) or not 1 <= len(screenshots) <= 3:
            raise CatalogError(f"{where}: expected one to three screenshots")
        images = []
        for index, encoded in enumerate(screenshots):
            data = decode_base64(encoded, MAX_SCREENSHOT_BYTES, f"{where}: screenshot {index + 1}")
            kind = image_format(data)
            if kind is None:
                raise CatalogError(f"{where}: screenshot {index + 1} is not PNG, JPEG or HEIC")
            images.append((kind, data))
        listings.append(
            dict(
                id=identifier,
                version=version,
                title=text_field(listing, "title", 80, where),
                summary=text_field(listing, "summary", 600, where),
                creator=text_field(listing, "creator", 120, where),
                license=text_field(listing, "license", 160, where),
                source=text_field(listing, "source", 300, where, optional=True),
                tags=[text_field({"tag": tag}, "tag", 40, where) for tag in tags],
                appearance=appearance,
                accent=color_field(package, "accent", where),
                background=color_field(package, "background", where),
                images=images,
            )
        )
    return listings


# ---- images ----


def tool(name):
    for candidate in (shutil.which(name), f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"/usr/bin/{name}"):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(f"{name} is required to convert screenshots and was not found")


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=180, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    if result.returncode != 0:
        raise CatalogError(f"{Path(arguments[0]).name} failed: {result.stderr.decode(errors='replace').strip()[:200]}")
    return result


def tool_versions():
    cwebp = run([tool("cwebp"), "-version"]).stdout.decode().split()[0]
    sips = (run([tool("sips"), "--version"]).stdout.decode().split() or ["unknown"])[0]
    return {"cwebp": cwebp, "sips": sips}


def png_size(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or data[12:16] != b"IHDR":
        raise CatalogError("decoder did not produce a PNG")
    return struct.unpack(">II", data[16:24])


def to_webp(kind, data, where="screenshot"):
    """Decode one screenshot to pixels and return (webp bytes, width, height, mode).

    sips decodes every accepted format (including HEIC) to a temporary PNG in sRGB, so the
    color profile can be dropped without shifting colors. cwebp then writes only pixels:
    -metadata none leaves out EXIF, XMP and ICC.
    """
    with tempfile.TemporaryDirectory(prefix="pathem-themes-") as folder:
        source = Path(folder) / f"in.{kind}"
        decoded = Path(folder) / "decoded.png"
        source.write_bytes(data)
        run([tool("sips"), "-s", "format", "png", "--matchTo", SRGB_PROFILE, str(source), "--out", str(decoded)])
        if not decoded.is_file():
            raise CatalogError(f"{where}: could not be decoded")
        width, height = png_size(decoded.read_bytes()[:32])
        if not (1 <= width <= MAX_PIXELS_PER_SIDE and 1 <= height <= MAX_PIXELS_PER_SIDE):
            raise CatalogError(f"{where}: {width}x{height} is outside the size limit")
        outputs = {}
        for mode, options in (("lossless", ["-lossless", "-z", "9"]), ("q90", ["-q", "90", "-m", "6"])):
            target = Path(folder) / f"{mode}.webp"
            run([tool("cwebp"), "-quiet", *options, "-metadata", "none", str(decoded), "-o", str(target)])
            outputs[mode] = target.read_bytes()
    mode = "lossless" if len(outputs["lossless"]) <= len(outputs["q90"]) else "q90"
    return outputs[mode], width, height, mode


def convert(listings):
    """Attach content-addressed WebP files to each listing. Returns {relative path: bytes}."""
    files = {}
    jobs = [(kind, data, f'theme {listing["id"]}: screenshot {index + 1}') for listing in listings for index, (kind, data) in enumerate(listing["images"])]
    # Encoding is the slow part; a few at a time is enough. map() keeps the catalog order.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = iter(list(pool.map(lambda job: to_webp(*job), jobs)))
    for listing in listings:
        shots = []
        for index, (kind, data) in enumerate(listing["images"]):
            webp, width, height, mode = next(results)
            name = hashlib.sha256(webp).hexdigest()[:20] + ".webp"
            files[f"{IMAGE_DIR}/{name}"] = webp
            shots.append(dict(file=name, width=width, height=height, mode=mode, bytes=len(webp), input=kind, inputSha256=hashlib.sha256(data).hexdigest()))
        listing["shots"] = shots
    return files


# ---- page ----


def swatch(label, color):
    if color is None:
        return f'<li><span class="sw sw-none" aria-hidden="true"></span><span>{label}</span> <span class="hex">System</span></li>'
    return (
        f'<li><svg class="sw" width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" focusable="false">'
        f'<rect width="18" height="18" fill="{esc(color)}"/></svg><span>{label}</span> <code class="hex">{esc(color)}</code></li>'
    )


def card(listing, eager):
    title = esc(listing["title"])
    shots = listing["shots"]
    first = shots[0]
    loading = "eager" if eager else "lazy"
    # data-appearance is what the filter's stylesheet rules match. It comes from the theme
    # package (validated against APPEARANCES), never from the free-text tags.
    parts = [f'<li class="theme" id="theme-{listing["id"]}" data-appearance="{listing["appearance"]}"><article aria-labelledby="title-{listing["id"]}">']
    parts.append(
        f'<a class="shot" href="/themes/img/{first["file"]}"><img src="/themes/img/{first["file"]}" width="{first["width"]}" height="{first["height"]}" '
        f'loading="{loading}" decoding="async" alt="{title} theme in Pathem. {esc(listing["summary"])}"></a>'
    )
    if len(shots) > 1:
        parts.append(f'<ul class="more" aria-label="More screenshots of {title}">')
        for number, shot in enumerate(shots[1:], start=2):
            parts.append(
                f'<li><a href="/themes/img/{shot["file"]}"><img src="/themes/img/{shot["file"]}" width="{shot["width"]}" height="{shot["height"]}" '
                f'loading="lazy" decoding="async" alt="{title}, screenshot {number} of {len(shots)}"></a></li>'
            )
        parts.append("</ul>")
    parts.append('<div class="body">')
    parts.append(f'<div class="head"><h2 id="title-{listing["id"]}">{title}</h2><span class="mode mode-{listing["appearance"]}">{APPEARANCES[listing["appearance"]]}</span></div>')
    parts.append(f'<p class="by">by {esc(listing["creator"])}</p>')
    parts.append(f'<p class="summary">{esc(listing["summary"])}</p>')
    parts.append(f'<ul class="swatches" aria-label="Theme colors">{swatch("Background", listing["background"])}{swatch("Accent", listing["accent"])}</ul>')
    if listing["tags"]:
        parts.append('<ul class="tags" aria-label="Tags">' + "".join(f"<li>{esc(tag)}</li>" for tag in listing["tags"]) + "</ul>")
    parts.append(f'<dl class="meta"><div><dt>License</dt><dd>{esc(listing["license"])}</dd></div>')
    if listing["source"]:
        # Shown as text, never as a link: a submitted URL is not ours to vouch for.
        parts.append(f'<div><dt>Source</dt><dd>{esc(listing["source"])}</dd></div>')
    parts.append(f'<div><dt>Revision</dt><dd>{listing["version"]}</dd></div></dl>')
    parts.append("</div></article></li>")
    return "".join(parts)


def count_phrase(listings):
    count = len(listings)
    return f"{count} {'theme' if count == 1 else 'themes'}"


def appearance_filter(listings):
    """The All / Light / Dark control, or "" when it could not narrow the list.

    It is three radio inputs and no script: the stylesheet hides the other appearance with
    :has() on the checked radio. A theme that follows the system works in both appearances,
    so it is counted and shown under Light and under Dark. Each count is the number of
    cards that choice leaves visible.
    """
    light = sum(1 for listing in listings if listing["appearance"] != "dark")
    dark = sum(1 for listing in listings if listing["appearance"] != "light")
    if light == len(listings) or dark == len(listings):
        return ""
    parts = ['<fieldset class="filter">\n<legend>Show</legend>\n<div class="choices">']
    for key, label, count in (("all", "All", len(listings)), ("light", "Light", light), ("dark", "Dark", dark)):
        checked = " checked" if key == "all" else ""
        noun = "theme" if count == 1 else "themes"
        parts.append(
            f'<input type="radio" name="appearance" id="show-{key}" value="{key}"{checked}>'
            f'<label for="show-{key}">{label} <span class="n">{count}</span><span class="vh"> {noun}</span></label>'
        )
    parts.append("</div>\n</fieldset>")
    return "\n".join(parts)


def render(listings, stylesheet_version):
    description = "Browse the community themes for Pathem, the native macOS file manager. Every theme is free under its listed license and installs from inside the app."
    cards = "\n".join(card(listing, index < 3) for index, listing in enumerate(listings))
    if listings:
        # The filter's labels carry the counts; without a filter, a plain count line does.
        above = appearance_filter(listings) or f'<p class="count">{count_phrase(listings)}</p>'
        gallery = f'{above}\n<ul class="gallery">\n{cards}\n</ul>'
    else:
        gallery = '<p class="count">No themes are published yet. Check back soon.</p>'
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Community themes | Pathem</title>
<meta name="description" content="{esc(description)}">
<link rel="canonical" href="{BASE}/themes/">
<link rel="icon" type="image/svg+xml" href="/assets/favicon.svg">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/favicon-32.png">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0e131c">
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#ffffff">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Pathem">
<meta property="og:title" content="Community themes for Pathem">
<meta property="og:description" content="{esc(description)}">
<meta property="og:url" content="{BASE}/themes/">
<meta property="og:image" content="{SOCIAL_IMAGE}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Community themes for Pathem">
<meta name="twitter:description" content="{esc(description)}">
<meta name="twitter:image" content="{SOCIAL_IMAGE}">
<link rel="stylesheet" href="/assets/themes.css?v={stylesheet_version}">
</head>
<body>
<a class="skip-link" href="#main-content">Skip to content</a>
<header class="nav wrap">
  <a class="brand" href="/">
    <img src="/assets/logo-64.png" alt="Pathem app icon" width="30" height="30">
    <b class="wm">Path<i>em</i></b>
  </a>
  <nav class="nav-links" aria-label="Website">
    <a href="/#features">Features</a>
    <a class="guide-link" href="/docs/">Guides</a>
    <a class="here" href="/themes/" aria-current="page">Themes</a>
    <a class="home-link" href="/">Home</a>
  </nav>
</header>

<main class="wrap" id="main-content" tabindex="-1">
  <div class="intro">
    <span class="eyebrow">~/themes</span>
    <h1>Community themes</h1>
    <p class="lede">Looks for Pathem made and shared by the people who use it. A theme tints the whole window and brings its own folder style, file icons, and toolbar glyphs.</p>
    <p>Every theme here is free to use under the license listed on its card. To install one, open Pathem, go to Settings &gt; Appearance, and click Themes… to open the gallery. You can preview a theme on your own window before you keep it.</p>
    <p class="links"><a href="/docs/themes/#gallery">Read the Themes guide</a><a href="/docs/themes/#submit">Submit your own theme</a></p>
  </div>
  <section class="published" aria-label="Published themes">
{gallery}
  </section>
</main>

<footer class="wrap">
  <div class="foot-top">
    <a class="brand" href="/">
      <img src="/assets/logo-64.png" alt="Pathem app icon" width="30" height="30">
      <b class="wm">Path<i>em</i></b>
    </a>
    <div class="foot-links">
      <a href="/docs/">Documentation &amp; guides</a>
      <a href="/themes/" aria-current="page">Community themes</a>
      <a href="/privacy/">Privacy</a>
      <a href="https://github.com/Scarcrux/Pathem/security/policy">Security</a>
      <a href="https://github.com/Scarcrux/Pathem">GitHub</a>
    </div>
  </div>
  <p class="foot-note">&copy; 2026 Scarcrux LLC &middot; pathem.app &middot; Themes belong to their creators and are shared under the licenses shown.</p>
</footer>
</body>
</html>
'''


# ---- build, check, audit ----


def source_label(source):
    """A public-safe name for the record: the URL, or a local file's name without its folder."""
    return source if source.startswith("https://") else Path(source).name


def load(source):
    if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*://", source):
        url = urllib.parse.urlsplit(source)
        if url.scheme != "https" or not url.hostname or url.username:
            raise CatalogError("catalog URL must be plain https")
        request = urllib.request.Request(source, headers={"User-Agent": "pathem-site-build"})
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urllib.parse.urlsplit(response.geturl())
            if final.scheme != "https" or final.hostname != url.hostname:
                raise CatalogError("catalog URL redirected to another host")
            data = response.read(MAX_CATALOG_BYTES + 1)
    else:
        path = Path(source).expanduser()
        if path.stat().st_size > MAX_CATALOG_BYTES:
            raise CatalogError("catalog exceeds the size limit")
        data = path.read_bytes()
    if len(data) > MAX_CATALOG_BYTES:
        raise CatalogError("catalog exceeds the size limit")
    return data


def stylesheet_version(root=ROOT):
    return hashlib.sha256((root / STYLESHEET).read_bytes()).hexdigest()[:10]


def build(catalog_bytes, label, root=ROOT, updated=None):
    """Return ({relative path: bytes}, record). Pure for a given catalog, stylesheet and tools."""
    try:
        catalog = json.loads(catalog_bytes)
    except (ValueError, RecursionError):
        raise CatalogError("catalog is not JSON") from None
    listings = validate(catalog)
    files = convert(listings)
    files[PAGE] = render(listings, stylesheet_version(root)).encode("utf-8")
    record = {
        "source": label,
        "catalogSha256": hashlib.sha256(catalog_bytes).hexdigest(),
        "themes": len(listings),
        "tools": tool_versions(),
        "pageSha256": hashlib.sha256(files[PAGE]).hexdigest(),
        "images": [
            dict(theme=listing["id"], screenshot=index + 1, **{key: shot[key] for key in ("file", "width", "height", "mode", "bytes", "input", "inputSha256")})
            for listing in listings
            for index, shot in enumerate(listing["shots"])
        ],
    }
    previous = read_record(root)
    if updated is None:
        # The date moves only when the published output does, so a rebuild stays byte-identical.
        same = previous is not None and {**previous, "updated": None} == {**record, "updated": None}
        updated = previous["updated"] if same else datetime.date.today().isoformat()
    record["updated"] = updated
    files[RECORD] = (json.dumps(record, indent=2) + "\n").encode("utf-8")
    return files, record


def read_record(root=ROOT):
    path = root / RECORD
    return json.loads(path.read_text()) if path.is_file() else None


def differences(files, root=ROOT):
    """Paths that are missing, changed, or stale compared with a build."""
    errors = [name for name, content in files.items() if not (root / name).is_file() or (root / name).read_bytes() != content]
    folder = root / IMAGE_DIR
    if folder.is_dir():
        errors += [f"{IMAGE_DIR}/{path.name} (stale)" for path in sorted(folder.iterdir()) if f"{IMAGE_DIR}/{path.name}" not in files]
    return errors


def write(files, root=ROOT):
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_bytes() != content:
            path.write_bytes(content)
    folder = root / IMAGE_DIR
    if folder.is_dir():
        for path in folder.iterdir():
            if f"{IMAGE_DIR}/{path.name}" not in files:
                path.unlink()


def audit(root=ROOT):
    """Check the committed output against itself, with no catalog and no image tools.

    Returns a list of problems: the page must match the record, every image must be the
    file its name says it is, and nothing unreferenced may sit in the image folder.
    """
    record = read_record(root)
    if record is None:
        return [f"{RECORD} is missing"]
    problems = []
    page = (root / PAGE).read_bytes() if (root / PAGE).is_file() else b""
    if hashlib.sha256(page).hexdigest() != record["pageSha256"]:
        problems.append(f"{PAGE} does not match the build record")
    text = page.decode("utf-8", errors="replace")
    if f"/assets/themes.css?v={stylesheet_version(root)}" not in text:
        problems.append(f"{PAGE} links a stale {STYLESHEET}; rebuild the page")
    expected = {image["file"] for image in record["images"]}
    referenced = set(re.findall(r'src="/themes/img/([^"]+)"', text))
    if referenced != expected:
        problems.append("the page and the record list different images")
    folder = root / IMAGE_DIR
    present = {path.name for path in folder.iterdir()} if folder.is_dir() else set()
    problems += [f"{IMAGE_DIR}/{name} is missing" for name in sorted(expected - present)]
    problems += [f"{IMAGE_DIR}/{name} is not referenced" for name in sorted(present - expected)]
    for name in sorted(expected & present):
        data = (folder / name).read_bytes()
        if hashlib.sha256(data).hexdigest()[:20] + ".webp" != name:
            problems.append(f"{IMAGE_DIR}/{name} does not match its content hash")
        if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
            problems.append(f"{IMAGE_DIR}/{name} is not WebP")
        if any(chunk in data for chunk in (b"EXIF", b"XMP ", b"ICCP")):
            problems.append(f"{IMAGE_DIR}/{name} carries metadata")
    return problems


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("source", nargs="?", default=LIVE_CATALOG, help="catalog file or https URL (default: the live catalog)")
    parser.add_argument("--check", action="store_true", help="fail if the generated files differ; do not write")
    args = parser.parse_args(arguments)
    try:
        previous = read_record()
        files, record = build(load(args.source), source_label(args.source), updated=previous["updated"] if args.check and previous else None)
    except (CatalogError, OSError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if args.check:
        errors = differences(files) + audit()
        if errors:
            print("Themes page missing, stale or changed: " + ", ".join(errors), file=sys.stderr)
            if previous and previous.get("tools") != record["tools"]:
                print(f"Note: built with {previous.get('tools')}, checking with {record['tools']}; encoders differ between versions.", file=sys.stderr)
            return 1
    else:
        write(files)
    images = [content for name, content in files.items() if name.startswith(IMAGE_DIR)]
    modes = sorted({image["mode"] for image in record["images"]})
    print(
        f"PASS: {record['themes']} themes from {record['source']}; {len(images)} WebP images ({', '.join(modes) or 'none'}), "
        f"{sum(map(len, images))} bytes; page {len(files[PAGE])} bytes; dated {record['updated']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
