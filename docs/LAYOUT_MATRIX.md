# Layout matrix (Mission 53 task 2)

Design and acceptance criteria, written before implementation. Owner request
2026-11-15: Claude designs, the `pathem-codex-2` lane implements.

## Trigger and evidence

Three layout defects reached `main` and were found only because someone looked at a
screenshot on 2026-11-15:

| Defect | Commit that fixed it | What a check would have had to notice |
|---|---|---|
| Showing the terminal drawer left the browser and the terminal at 0 pt (blank window) | `26f0a1f` | a visible primary region with zero height |
| Icon-view names lost the bottom of their second line | `5084a6c` | a label whose frame is shorter than its text needs |
| The Rename sheet's suggestion button sat 3 pt outside its accessory | `b2923f4` | a control outside its container |

Each was deterministic, and each belonged to a state the existing suites never laid out
(drawer shown, two-line icon names, first frame of a sheet). The existing
`PATHEM_LAYOUT_UI_TEST` covers listing boundaries in one configuration only.

## Goal

One harness that lays the real window out in many configurations and applies the same
structural checks to every one, so the next defect of this kind fails a gate instead of
waiting for a screenshot. It asserts geometry and state, not pixels. Pixel baselines are
task 1 and come later.

## Matrix

Staged over `DemoWorkspace` (never the real home folder), reusing the staging in
`BrowserViewController+SiteShots.swift`.

- Window size: minimum (720x420), default (1100x700), wide (1680x1000).
- Left pane view: list, icon, gallery, column, tree. The right pane stays in list view,
  except one row of cells where both panes use the same non-list view.
- Panels, one at a time and then the listed pairs: none, sidebar hidden, compact sidebar,
  preview pane, terminal drawer, torrent drawer, Drop Stack (shelf), detail view;
  terminal + torrent, preview + terminal.
- Pane ratio: 50/50, 25/75, 75/25 (default size and list view only).
- Appearance: dark for every cell; light for the default-size row.
- Transitions, on the default size: toggle each panel on then off, switch through all five
  views and back, resize default to minimum to wide to default.

This is a covering set, not the full product. Target under 150 cells and under four
minutes. If it runs longer, drop pairs before dropping axes, and record what was dropped.

## Checks applied to every cell

Walk the visible view tree from the window's content view.

1. No collapsed region. Each primary region that is supposed to be visible (sidebar when
   shown, each pane's content, each shown panel) is at least 40 pt in both dimensions.
2. Containment. No visible control (button, text field, table, collection view, split
   subview) extends more than 1 pt outside its superview's bounds, clip views excepted.
3. No sibling overlap among the controls of one toolbar, header, status bar or button row
   (frames compared in the row's coordinate space; 1 pt tolerance).
4. Text fits vertically. For every visible `NSTextField` label, the frame height is at
   least the cell's required height for its width, less 1 pt. Horizontal truncation is
   allowed only where the field's line-break mode truncates.
5. No layout ambiguity or unsatisfiable constraints reported for the window during the
   cell (`hasAmbiguousLayout` on the regions above, and no constraint-conflict log line).

After each transition:

6. Selection is kept: the same names are selected before and after.
7. The viewport does not jump: the first visible row or item is unchanged, unless the
   transition is a view switch.
8. Reversibility: toggling a panel on then off restores every primary region to within
   2 pt of its starting frame.

On a failing cell, print one receipt line with the cell name, the failed check, and the
offending view's class, identifier and frame, and write an in-process render of the window
(`debugRenderWindowAt2x`) beside it so the failure can be looked at.

## Controls: the matrix must be able to go red

A check that has only ever been green is not known to work.

- Predicate controls, in the harness itself: a synthetic view tree with a known-good
  layout passes, and one synthetic defect per check (zero-height region, control outside
  its parent, overlapping siblings, short label) fails that check and only that check.
- Regression controls, behind `#if DEBUG`: `PATHEM_LAYOUT_MATRIX_INJECT=terminal-collapse`,
  `icon-label-short` and `accessory-short` each undo one of the three fixes above at run
  time. With an injection set, the matrix must fail, in the cells that show that state,
  with the check named in the table at the top. The Rename sheet control may live in the
  existing dialog-layout sample if sheets are out of the matrix's scope; say which.

## Validation before the full run

1. Build the harness with three cells only (default size: list, icon view, list with the
   terminal drawer) plus all controls.
2. Report a verdict per criterion: every predicate control behaves; each injection turns
   the right cell red with the right check; with no injection the three cells pass.
3. Only then expand to the full matrix.

The design is broken if an injection leaves the matrix green, if a predicate control
fails a check other than its own, or if the clean three-cell run is red for a reason that
is not a real defect.

## Findings

The full matrix will probably find real defects. For each: do not loosen the check to get
to green. Record the receipt, convict the mechanism, fix it in its own commit with the
cell as its regression test, or record it as an open finding on Mission 53 if the fix is
not obvious. A real defect that stays open keeps its cell red and listed, not skipped.

## Delivery

- `PATHEM_LAYOUT_MATRIX_TEST=1`, printing `LAYOUTMATRIX: PASS|FAIL <cell> <check>` lines
  and a final `RESULT:` line, added as a scenario in `test/e2e/run.sh` so `make ci` runs it.
- Unit 1: harness, checks, controls, three-cell validation.
- Unit 2: full matrix, receipts, wired into the gate.
- Unit 3: fixes for what it finds, one commit per mechanism.

Later, on the same staging and harness: task 1 (approved visual baselines for stable
surfaces, using the composited capture in `scripts/site-shots.sh`) and task 11 (every
transient surface in a real window). Not part of this hand-off.

## Out of scope and limits

- No change to the display mode, no install to `/Applications`, no site deploy.
- Pixel correctness, colours and materials are not checked here.
- Captures that need Screen Recording must be started from Terminal (see
  `scripts/site-shots.sh`); the matrix itself needs none.
