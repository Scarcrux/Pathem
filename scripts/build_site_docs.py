#!/usr/bin/env python3
"""Build dependency-free, crawlable user guides. No source code is copied to the site."""

import argparse
import html
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "docs/website/guides.json"
BASE = "https://pathem.app"
SOCIAL_IMAGE = f"{BASE}/assets/social-card.png"
# Hand-written pages are not generated, so their sitemap dates are kept here. Bump the
# date when the page changes (git log -1 --format=%cs -- site/<file>). The guide pages use
# the larger of the content date and TEMPLATE_UPDATED, which is bumped when the shell changes.
STATIC_PAGES = {"/": "2026-11-17", "/privacy/": "2026-11-17"}
TEMPLATE_UPDATED = "2026-11-17"


def inline(value):
    """The authoring format supports only escaped prose, `code`, and local [links]."""
    tokens = re.split(r"(`[^`]+`|\[[^\]]+\]\(/docs/[^\s)]*\))", value)
    output = []
    for token in tokens:
        if token.startswith("`") and token.endswith("`"):
            output.append(f"<code>{html.escape(token[1:-1])}</code>")
        elif match := re.fullmatch(r"\[([^\]]+)\]\((/docs/[^\s)]*)\)", token):
            output.append(f'<a href="{html.escape(match[2], quote=True)}">{html.escape(match[1])}</a>')
        else:
            output.append(html.escape(token))
    return "".join(output)


def validate(data, root=ROOT):
    ids = set()
    categories = {category["id"] for category in data["categories"]}
    for guide in data["guides"]:
        slug = guide["id"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", slug) or slug in ids:
            raise ValueError(f"Invalid or duplicate guide id: {slug}")
        ids.add(slug)
        if guide["category"] not in categories:
            raise ValueError(f"Unknown category: {slug}")
        if not guide["title"] or not guide["description"] or len(guide["sections"]) < 3:
            raise ValueError(f"Incomplete guide: {slug}")
        sections = set()
        step_count = 0
        for section in guide["sections"]:
            if section["id"] in sections or not re.fullmatch(r"[a-z][a-z0-9-]*", section["id"]):
                raise ValueError(f"Invalid section id: {slug}")
            sections.add(section["id"])
            step_count += len(section.get("steps", []))
        if step_count < 4:
            raise ValueError(f"Guide needs actionable steps: {slug}")
        if not guide.get("sources"):
            raise ValueError(f"Guide needs source evidence: {slug}")
        for source in guide["sources"]:
            path = (root / source["path"]).resolve()
            if not path.is_relative_to(root.resolve()):
                raise ValueError("Source path leaves repository")
            text = path.read_text()
            for needle in source["needles"]:
                if needle not in text:
                    raise ValueError(f"Source contract changed: {slug}: {source['path']}: {needle}")
    for guide in data["guides"]:
        for related in guide["related"]:
            if related not in ids or related == guide["id"]:
                raise ValueError(f"Invalid related guide: {guide['id']}: {related}")


def navigation(data, active=None):
    parts = ['<nav aria-label="Guide topics"><a class="all-guides" href="/docs/">All guides</a>']
    for category in data["categories"]:
        parts.append(f'<h2>{html.escape(category["title"])}</h2><ul>')
        for guide in data["guides"]:
            if guide["category"] == category["id"]:
                current = ' aria-current="page"' if guide["id"] == active else ""
                parts.append(f'<li><a href="/docs/{guide["id"]}/"{current}>{html.escape(guide["title"])}</a></li>')
        parts.append("</ul>")
    return "".join(parts) + "</nav>"


def shell(data, title, description, path, content, active=None):
    nav = navigation(data, active)
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} | Pathem Guides</title>
<meta name="description" content="{html.escape(description, quote=True)}">
<link rel="canonical" href="{BASE}{path}">
<meta property="og:title" content="{html.escape(title, quote=True)} | Pathem Guides">
<meta property="og:description" content="{html.escape(description, quote=True)}">
<meta property="og:type" content="article"><meta property="og:url" content="{BASE}{path}">
<meta property="og:site_name" content="Pathem">
<meta property="og:image" content="{SOCIAL_IMAGE}">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Pathem: a fast, native macOS file manager">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{html.escape(title, quote=True)} | Pathem Guides">
<meta name="twitter:description" content="{html.escape(description, quote=True)}">
<meta name="twitter:image" content="{SOCIAL_IMAGE}">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/docs/docs.css"><script src="/docs/docs.js" defer></script>
</head><body>
<a class="skip-link" href="#main-content">Skip to content</a>
<header class="topbar"><a class="brand" href="/"><img src="/assets/logo-64.png" width="28" height="28" alt="">Path<span>em</span></a>
<nav aria-label="Website"><a href="/">Overview</a><a href="/docs/" aria-current="{ 'true' if active else 'page' }">Guides</a></nav></header>
<div class="doc-layout"><aside class="sidebar">{nav}</aside>
<div class="reading"><details class="mobile-nav"><summary>Browse all guides</summary>{nav}</details>
<main id="main-content" tabindex="-1">{content}</main>
<footer><p>Pathem user guides · English UI · Updated {html.escape(data["updated"])}</p>
<p>Shortcuts are defaults and may differ if customized. Features can depend on your build, provider, hardware, and macOS version.</p>
<a href="/docs/">All guides</a> · <a href="/">Back to Pathem</a> · <a href="/privacy/">Privacy</a> · <a href="mailto:security@pathem.app">Security contact</a></footer></div></div>
</body></html>
'''


def search_form(value=""):
    return f'''<form class="guide-search" action="/docs/" method="get" role="search">
<label for="guide-query">Search the guides</label><div class="search-row">
<input id="guide-query" name="q" type="search" placeholder="Try relative dates, move, Android…" autocomplete="off" value="{html.escape(value, quote=True)}">
<button type="submit">Search</button></div></form>'''


def text_content(guide):
    values = [guide["title"], guide["description"], *guide.get("keywords", [])]
    for section in guide["sections"]:
        values.append(section["title"])
        for key in ["paragraphs", "steps", "bullets"]:
            values.extend(section.get(key, []))
        if section.get("note"):
            values.append(section["note"])
        if section.get("code"):
            values.append(section["code"])
    return " ".join(values)


def build(data):
    validate(data)
    lookup = {guide["id"]: guide for guide in data["guides"]}
    categories = {category["id"]: category["title"] for category in data["categories"]}
    files = {}
    intro = f'''<p class="eyebrow">Pathem documentation</p><h1>Learn your way around.</h1>
<p class="lead">Practical, step-by-step guides for everyday file work and the tools beyond it.</p>
<p class="release-note">Already have a trusted build? Start below. A public prebuilt download is not published yet. <a href="/docs/install/">Installation and requirements</a>.</p>
{search_form()}<p class="search-status" id="search-status" role="status" aria-live="polite"></p>
<section id="search-results" aria-label="Search results" hidden></section>
<noscript><p>Search needs JavaScript. Every guide below is readable without it; use your browser’s Find command to browse this index.</p></noscript>
<div id="guide-directory"><section class="start-here"><h2>Start with a task</h2><div class="task-links">
<a href="/docs/first-steps/">Take a first tour <span>Two panes, navigation, and a safe practice folder</span></a>
<a href="/docs/copy-move/">Copy or move files <span>Choose a destination and handle conflicts safely</span></a>
<a href="/docs/views-dates/">Make folders easier to read <span>Views, sorting, groups, Today and Yesterday</span></a></div></section>'''
    for category in data["categories"]:
        intro += f'<section class="category" id="{category["id"]}"><h2>{html.escape(category["title"])}</h2><div class="guide-grid">'
        for guide in data["guides"]:
            if guide["category"] == category["id"]:
                count = sum(len(section.get("steps", [])) for section in guide["sections"])
                intro += f'<a class="guide-card" href="/docs/{guide["id"]}/"><h3>{html.escape(guide["title"])}</h3><p>{html.escape(guide["description"])}</p><span>{count} practical steps</span></a>'
        intro += "</div></section>"
    intro += "</div>"
    files["site/docs/index.html"] = shell(data, "Documentation", "Step-by-step Pathem guides for installation, moving files, views, search, remote connections, customization and troubleshooting.", "/docs/", intro)
    search = []
    for guide in data["guides"]:
        slug = guide["id"]
        path = f"/docs/{slug}/"
        content = f'<nav class="breadcrumbs" aria-label="Breadcrumb"><a href="/docs/">Guides</a><span>/</span><a href="/docs/#{guide["category"]}">{html.escape(categories[guide["category"]])}</a></nav>'
        content += f'<article><h1>{html.escape(guide["title"])}</h1><p class="lead">{html.escape(guide["description"])}</p>'
        content += '<nav class="contents" aria-label="On this page"><h2>On this page</h2><ul>'
        for section in guide["sections"]:
            content += f'<li><a href="#{section["id"]}">{html.escape(section["title"])}</a></li>'
        content += "</ul></nav>"
        for section in guide["sections"]:
            content += f'<section id="{section["id"]}"><h2>{html.escape(section["title"])}</h2>'
            for paragraph in section.get("paragraphs", []):
                content += f"<p>{inline(paragraph)}</p>"
            for key, tag in [("steps", "ol"), ("bullets", "ul")]:
                if section.get(key):
                    content += f"<{tag}>" + "".join(f"<li>{inline(item)}</li>" for item in section[key]) + f"</{tag}>"
            if section.get("code"):
                content += f'<pre><code>{html.escape(section["code"])}</code></pre>'
            if section.get("note"):
                content += f'<aside class="callout" aria-label="Important"><strong>Keep in mind</strong><p>{inline(section["note"])}</p></aside>'
            content += "</section>"
        content += '<section class="related"><h2>Keep going</h2><ul>'
        for related in guide["related"]:
            content += f'<li><a href="/docs/{related}/">{html.escape(lookup[related]["title"])}</a></li>'
        content += "</ul></section></article>" + search_form()
        files[f"site/docs/{slug}/index.html"] = shell(data, guide["title"], guide["description"], path, content, slug)
        search.append(dict(title=guide["title"], description=guide["description"], category=categories[guide["category"]], url=path, text=text_content(guide)))
    files["site/docs/search-index.json"] = json.dumps(search, ensure_ascii=False, indent=2) + "\n"
    docs_date = max(data["updated"], TEMPLATE_UPDATED)
    entries = [(f"{path}", date) for path, date in STATIC_PAGES.items()]
    entries.insert(1, ("/docs/", docs_date))
    entries += [(f'/docs/{guide["id"]}/', docs_date) for guide in data["guides"]]
    files["site/sitemap.xml"] = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "".join(f"  <url><loc>{BASE}{path}</loc><lastmod>{date}</lastmod></url>\n" for path, date in entries) + "</urlset>\n"
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated files differ; do not write")
    args = parser.parse_args()
    data = json.loads(CONTENT.read_text())
    files = build(data)
    errors = []
    for name, content in files.items():
        path = ROOT / name
        if args.check:
            if not path.is_file() or path.read_text() != content:
                errors.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    expected = {ROOT / name for name in files}
    stale = set((ROOT / "site/docs").rglob("*.html")) - expected
    errors.extend(str(path.relative_to(ROOT)) for path in sorted(stale))
    if errors:
        print("Documentation output missing, stale or changed: " + ", ".join(errors), file=sys.stderr)
        return 1
    print(f"PASS: {len(data['guides'])} guides; {len(files)} deterministic generated files; source contracts verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
