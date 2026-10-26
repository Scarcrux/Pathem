# Website user documentation

The website previously consisted of a marketing landing page and shortcut overview.
The owner asked for extensive step-by-step guides. The repository's existing docs
primarily describe engineering and test evidence, not end-user workflows.

## Architecture and authoring

`docs/website/guides.json` is the source of 21 task guides in six categories. Each
guide has prerequisites/context, numbered steps, results or troubleshooting, related
guides, and source anchors. Its limited inline format accepts escaped prose,
backtick code, and local `[label](/docs/guide/)` links. It does not accept raw HTML.

`scripts/build_site_docs.py` generates complete static HTML, the search index, and
the sitemap. It never copies implementation source into the website. Edit the
content source, not generated HTML. The CSS and progressively enhanced local search
script are maintained directly in `site/docs/`. No framework, npm dependency,
external search provider, account, tracking script, or build-time AI is required.

Source anchors are an early drift alarm, not proof of every tutorial sentence or
hardware workflow. Review instructions against real command/menu/preferences code
when changing a feature. Recheck current release availability before publishing.
Do not promote unlanded MTP work, unavailable public downloads, unconditional undo,
or model-dependent features into supported guarantees.

## Local build and tests

```
make docs
make docs-check
make docs-browser
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:8765/docs/` for a preview. Routes use directory index.html
files and need no SPA rewrite. `docs-check` verifies deterministic generation,
source anchors, internal links/fragments, accessibility basics, sitemap/search
coverage, escaping, and search behavior. Its negative controls must reject broken
links, missing anchors, duplicate IDs, missing steps and changed source anchors.
The normal pre-commit gate runs these checks for documentation/site changes.
Relevant app/engine/CLI edits also run the Python-only source/output check, without
requiring a browser or adding Node to the native source gate.

`docs-browser` uses Node 22+ with built-in WebSocket and a dedicated headless Chrome
profile; it does not touch the user's browser or installed app. Set
`PATHEM_DOCS_CHROME` if Chrome is elsewhere and `PATHEM_DOCS_CAPTURES` for screenshots.
Temporary profiles are removed; screenshots are retained outside the checkout by
default. No Swift/app build or install is necessary for this website-only change.

## Browser criteria, written before the run

The initial sample must deliver actual desktop and mobile layouts, reject a
synthetically overflowing page, restore a known-good layout, and expand a real
mobile navigation menu. Only then run the full guide matrix. Every guide must
have readable content and no horizontal page overflow at 1280, 390 and 320 pixels.
Test the landing-page guide link at each width, basic light/dark text contrast;
task search, empty/no-result queries, clearing and shared
URLs; keyboard focus; blocked search-index fallback; no-script readable navigation;
and absence of uncaught browser errors. Inspect screenshots before claiming visual
verification. A failed capture or test must stay recorded, not be counted as a pass.

## Publishing boundary

These commands only generate and serve local files. They do not deploy, push,
change repository visibility, or publish private source. Website publication is
separate and must follow the project's owner-approval and privacy requirements.
The landing-page and docs navigation can ship together from the existing `site/`
root once that publication is authorized.

## Verification receipt

Local build/checks ACTUAL exit0: 21 guides, 70 sections, 203 numbered steps; nine
static/source/link tests and four search tests, including discriminating negative
controls. Real browser final ACTUAL exit0: 152 checks, all 21 guides at desktop,
390px and 320px, landing-page discovery, light/dark basic text contrast, live search,
keyboard focus/clearing, failed-index fallback, no-script accessibility tree, and
actual owned browser-group closure. Four desktop/mobile/theme screenshots were
visually inspected; no clipped body content or missing chrome was accepted.

Initial source verification correctly rejected an incorrectly named opener
evidence anchor; the guide now references the production opener rules. The first
145 browser assertions passed, but Chrome left an owned network helper alive and
the runner needed scoped cleanup. The corrected runner starts Chrome in its own
process group and verifies closure before reporting success. Subsequent runs
closed naturally with 146 checks, then 152 after expanding the checks. No owner
browser profile or app process was touched. No Swift/native app rebuild, install,
full application CI, push, deployment, or repository-visibility change occurred.
Normal commit-gate results are recorded in the roadmap/commit receipt.
