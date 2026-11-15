# Visual baselines (Mission 53 task 1)

Design and acceptance criteria, written before implementation. Owner request 2026-11-15:
Claude designs, the `pathem-codex-2` lane implements, after the transient-surfaces Unit 1.

## Trigger and evidence

The gates check captures for being usable, not for being right. `test/e2e/capture_quality.swift`
returns "usable-pixels-not-visual-approval", and `make ci` carries a standing skip:
"browser flow pixels (cached pixels rejected; native appearance unverified)". On 2026-11-15
three visible defects (ghost stripes below the last row, clipped icon names, a blank window
when the terminal opened) were found by a person looking at screenshots. The layout matrix
now catches structural defects; nothing catches a surface that is structurally fine and
looks wrong.

## What can be compared, and how

Two capture routes exist and they are not equivalent:

- In-process render (`cacheDisplay`). Needs no permission, works inside `make ci`, and is
  deterministic. It does not draw the gallery's large preview or window materials.
- Composited capture (`screencapture`, as `scripts/site-shots.sh` uses). Faithful, but needs
  the Screen Recording right, which a shell hosted inside another app does not have, and its
  pixels depend on the display scale.

So there are two tiers:

- Tier 1, in the gate: in-process renders of surfaces that draw faithfully that way,
  compared with approved baselines. A surface known not to render faithfully in-process
  (gallery preview, anything relying on vibrancy) is listed as excluded with its reason; it
  is never included with a baseline that happens to match.
- Tier 2, a release step: `scripts/site-shots.sh` captures compared with approved references
  by the same comparator. Run from Terminal, recorded in the release checklist, not part of
  `make ci`.

## Determinism comes first

A baseline is only useful if the same build produces the same image. Before any baseline:

1. Fixed dates. The demo workspace derives dates from "now", so the date column changes
   daily and "Today at ..." changes within a day. Add a fixed anchor for automation
   (`PATHEM_DEMO_ANCHOR`, an absolute date well in the past) so every file date is absolute
   and no row renders as Today or Yesterday.
2. Settled content. A render is taken only after the listing, folder sizes, tags, git state
   and thumbnails for the visible rows have arrived, using the readiness signals the layout
   matrix already has. No fixed sleeps as the only wait.
3. Fixed geometry and appearance: an explicit window size, appearance, accent colour,
   font size and sidebar width for every baseline, set by the harness and not read from
   preferences.
4. An environment key. Text rendering differs between macOS versions and scales. Each
   baseline set is stored under a key of macOS major.minor, backing scale and appearance.
   On a machine with no matching set the check reports SKIP with that reason. It never
   passes by default and never compares against another environment's images.

Evidence required: the same build rendered ten times gives byte-identical images for every
baseline surface, in two separate launches. A surface that cannot be made identical is
excluded and listed, not given a looser tolerance to hide the variation.

## Comparison

`test/e2e/visual_compare.swift`, alongside `capture_quality.swift`. For an actual image and
its baseline of the same size:

- Fail on a size mismatch.
- Count pixels whose largest channel difference exceeds 24 of 255. Pass only if they are
  under 0.2% of the image and no connected group of them is larger than 64 pixels. The
  second rule is what catches a moved or missing control that changes few pixels overall.
- On failure write the actual image and a difference image beside the receipt and print
  both paths with the differing fraction and the largest group's bounding box.

Self-test controls, run before the comparator is trusted, each on synthetic images:
identical images pass; one-pixel antialiasing noise passes; a control shifted by 3 points
fails; a missing label fails; a blank image fails; a wrong-size image fails.

## Baseline set

Small on purpose: under 30 images at 1x, each under 200 KB. Start with surfaces that are
stable and where a regression has already happened:

- Main window, list view, default size, dark and light.
- Main window, icon view (the clipped-name defect).
- Main window with the terminal drawer shown (the blank-window defect), terminal area masked.
- Tree view with empty space below the last row (the ghost-stripe defect).
- Sidebar, expanded and compact.
- Rename sheet with suggestions on, first frame.
- Settings, General pane.
- Reclaim Space window with remembered sizes.

Masks: a region that cannot be made deterministic (a live terminal, a progress animation)
is masked by an explicit rectangle recorded with the baseline, kept as small as possible.

## Approval

A baseline is approved by a person looking at it. `scripts/visual-baselines.sh record`
writes candidates to a scratch folder; they enter the repository only in a commit whose body
says who looked and what changed. `check` never updates anything. A changed baseline in a
commit must come with the difference image's summary (fraction and bounding box) in the body.

## Controls: the gate must be able to go red

With `PATHEM_LAYOUT_MATRIX_INJECT` set to `terminal-collapse`, `icon-label-short` and
`accessory-short` in turn, the corresponding baseline must fail. A new injection that
restores the ghost stripes must fail the tree baseline. With no injection every baseline
passes in the recording environment.

## Replacing the existing checks

List every existing capture check in `test/e2e/run.sh` and the `PATHEM_*_SHOT` hooks, and
for each say: replaced by a baseline, kept as a usability check for a surface outside the
set, or removed. The standing "browser flow pixels" skip either becomes a real comparison or
stays a skip with its reason restated; it does not silently turn into a pass.

## Validation before the full set

Unit 1: the anchor and determinism evidence, the comparator with its self-tests, three
baselines (list dark, icon view, Rename sheet first frame), the three matching injections
red, and the environment-key skip demonstrated by pointing the check at a deliberately wrong
key. Then stop: the reviewer looks at the three candidate images before any baseline is
committed. Unit 2: the rest of the set, the tier 2 comparison in `scripts/site-shots.sh`, and
the audit of existing checks.

The design is broken if ten renders of one build are not identical for an included surface,
if an injection leaves its baseline green, or if the check passes in an environment with no
matching baseline set.

## Out of scope

Approving how the app should look (that is the owner's call on each baseline), animation,
and video.
