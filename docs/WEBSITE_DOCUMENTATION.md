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
For read-only post-deployment checks, set `PATHEM_DOCS_TEST_ORIGIN=https://pathem.app`.
The normal gate still defaults to the local server; the override does not deploy
anything or change the live site. All interactions use an isolated browser profile.
Temporary profiles are removed; screenshots are retained outside the checkout by
default. No Swift/app build or install is necessary for this website-only change.

## Browser criteria, written before the run

### Built-in screenshot regression

The owner reported four joined, unlabeled screenshots on the homepage. The live
HTML has no figcaptions, and `figure.window { margin: 0 }` overrides the less
specific `.stage` margin. Before changing that markup, the focused browser check
must fail on this baseline. Acceptance: exactly four figures, each with a visible
feature heading and explanatory figcaption, loaded screenshot, caption outside
the clipped window frame, at least 24px between figures, and no horizontal
overflow at 1280, 390 and 320px in light and dark appearances. A synthetic
zero-gap control and a hidden-caption control must each be rejected by the same
measurement, followed by a restored good control. Capture and inspect actual
desktop/mobile screenshots. Run with `node test/site_docs_browser.cjs
--homepage-only`; these checks also run in the normal full browser suite.

Verification: the unchanged homepage failed the actual browser caption assertion
(exit1). After separating figures into an explicitly spaced grid and adding four
visible figcaptions outside window frames, the focused run passed28 checks. The
final `make docs-browser` exited0: nine static/source tests, four search tests,
and178 browser checks. Joined-figure and hidden-caption controls were rejected,
then restored controls passed. Initial screenshots caught the harness capturing
during the reveal animation; it now waits for actual animation completion and
requires fully opaque figures. Final desktop-dark and mobile-light captures were
visually inspected: all four screenshots and captions are clear and separated.
This verifies layout, not freshness of the existing July app screenshots. No
native app build or install was needed.

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

## Owner-approved publication receipt

The owner explicitly requested deployment after the source-only handoff. Discovery
confirmed the existing Cloudflare Pages `pathem` project serves `pathem.app`, uses
production branch `main`, and has no Git provider integration. Retained that host
and public website audience; did not create a separate Site or change repository
visibility. Uploaded only the unchanged `site/` tree from d90be85, excluding app
source, internal authoring/evidence metadata, Git history and credentials.

Wrangler4.122.0 ACTUAL exit0:47 assets,28 newly uploaded/19 reused, then successful
production deployment870f2623-91b0-4b70-85ce-bd48749e3b48. Deployment URL:
https://870f2623.pathem.pages.dev. Public guide hub: https://pathem.app/docs/.
Prior production deploymentc984c0a0-ac03-4030-8648-29e53c15ece0 remains in Pages
history for rollback; it was not deleted. Commit metadata identifies d90be85;
the dirty flag truthfully covers local roadmap/test-receipt work, not site changes.

Post-deployment ACTUAL exit0:27 production responses (home, guide index, all21
guides, CSS, JS, search index and sitemap) returned200 and matched local bytes
exactly. A nonexistent guide returned404, proving this was not a landing-page/SPA
fallback. The complete real-browser suite against https://pathem.app also exited0:
152 checks, including mobile/desktop layouts, actual search/keyboard behavior,
blocked-index fallback, no-script access, and owned browser-group closure. Live
screenshots confirmed the expected documentation UI. Local docs-check13 tests
also pass. No app build/install, Git push, DNS/access change or private app-source
publication occurred.

## Homepage screenshot repair deployment

Owner-requested follow-up527f6e1 separates the four built-in feature screenshots
and adds visible explanatory captions. Normal commit hooks passed and the change
landed before deployment. Wrangler4.122.0 exited0 deploying the existing `site/`
root to the existing `pathem` production project/main branch:
https://86087ee4.pathem.pages.dev. Only index.html was uploaded;46 assets were
reused. Prior deployment870f2623 remains available for rollback. No private app
source, internal evidence, credentials, Git history or visibility changes shipped.

Read-only production browser verification at https://pathem.app exited0 with28
checks: all four captioned images loaded and separated at1280/390/320px in both
appearances, contrasting joined/hidden-caption controls, no browser exceptions,
and actual owned-browser closure. The live mobile-light capture was inspected.
Production homepage SHA256 matched local index.html exactly:
`5b4d590949c63cde98b5995bd858296658f9972a7c4506d63897489f7f231a14`.
