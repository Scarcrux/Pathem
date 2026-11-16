# Transient surfaces (Mission 53 task 11)

Design and acceptance criteria, written before implementation. Owner request 2026-11-15:
Claude designs, the `pathem-codex-2` lane implements. Builds on `docs/LAYOUT_MATRIX.md`
and reuses its predicates, receipts, injections, isolation rules and known-findings gate.

## Trigger and evidence

The Rename sheet's suggestion button sat 3 pt outside its accessory on first display
(`b2923f4`). Nothing caught it because the layout matrix lays out the main window only, and
the existing transient checks cover four surfaces: the Rename dialog sample, the conflict
popover, the drop menu and transfer progress.

The app presents far more than that. A source count on 2026-11-15: 88 `NSAlert()`,
70 `beginSheetModal`, 34 `runModal()`, 22 `NSOpenPanel()`, 44 `NSMenu(`, 10 `beginSheet`,
1 `NSPopover()`, across 64 files.

## Goal

Every surface the app builds itself is presented in a real window at least once, checked
for structure and for the behaviour a user relies on (it appears, it can be cancelled, it
goes away, it can be shown again), and a defect fails a gate.

## Unit 0: inventory (first, and a deliverable in its own right)

A script (`test/transient_inventory.py`) that scans the sources and writes a checked-in
table, one row per presentation site: file and line, kind (alert, sheet, panel, popover,
menu, custom window), how it is presented (sheet, `runModal`, popover, window), whether it
carries custom content (an accessory view, a custom content view, more than two buttons,
a checkbox or text field), whether confirming it is destructive, and its class:

- A, custom content. Must be exercised by this task.
- B, plain alert (text and standard buttons only). Covered by one generic check, below.
- C, system panel (open and save panels, system menus). Presentation and dismissal only.

The gate fails when the scan finds a site that is not in the table, so a new surface cannot
be added without being classified.

Clarifications (2026-11-15, answering the implementing lane):

- One row per presentation expression, the call that puts the surface on screen. Each row
  links the place the surface is built (constructor or factory) by file and line, so the
  table has separate build and present locations and nothing is collapsed. A builder with
  several presentation sites gets one row per site. A builder that is never presented is
  listed and flagged, not dropped.
- Code that exists only for test harnesses (inside `#if DEBUG`, or in the UI-test, smoke,
  debug-hook and site-shot files) is excluded, by an explicit list with a count in the
  table's header, never silently.
- Class A also includes any surface whose confirm path destroys data without the Trash,
  whatever its content. The Reclaim Space "Delete Now" confirmation is class A by this
  rule: record it as "A (destructive)". Extracting its alert into a factory that the
  production path calls unchanged is in scope.
- Class B: the generic check is structural only (checks 1 to 3), built from the real
  strings in all six shipped languages at both sizes, with no presentation. Behaviour
  checks 4 to 8 apply to class B only for sites presented as sheets, once each, in Unit 2.
  In Unit 1 the ten sampled alerts get the structural check in six languages at both
  sizes, and three of the ten that are sheets (the lane's choice, named in the report)
  also get present, cancel and re-present. Class B sites that use `runModal` get the
  structural check only and are listed as such.

## Checks

Structure, for A and B, at the surface's first laid-out frame and again after any content
change (the Rename defect was a first-frame defect):

1. Containment, no overlap within a row, and text fits its label: the layout-matrix
   predicates, applied to the surface's content view.
2. The surface fits inside the visible screen, and a sheet fits its host at the minimum
   window size (720x420) and at the default size.
3. No ambiguous layout and no constraint-conflict log line while it is up.

Behaviour, for A, B and C:

4. It is presented where it should be: attached to the window that asked for it, or as a
   window of the expected kind. Nothing else is left on screen.
5. Cancel works and changes nothing: Escape (or the cancel button) dismisses it, no file
   is created, changed or removed, and no state the surface edits is committed.
6. The default button is the one Return triggers, and it is not the destructive one unless
   the inventory says that is intended.
7. Dismissal is complete: no attached sheet, no stray window, and the first responder
   returns to the view that had it.
8. It can be shown three times in a row with the same result and no accumulation (window
   count returns to its starting value each time).

Variants for class A: light and dark; a long-string locale (German) and a wide-glyph locale
(Japanese); and, where the surface shows a file name, a short name and a 255-character one.

Class B is covered generically rather than site by site: a check that builds each plain
alert's message and informative text from its real localized strings in every shipped
language and applies checks 1 and 2 to a standard alert of that content. Sites whose text
is assembled at run time are listed in the table with the longest plausible value used.

Scope of check 3 (2026-11-16, answering the implementing lane). Ambiguity is checked on
app-owned layout only: every view in a subtree the app supplied (an alert's accessory view,
or a custom surface's content view, and their descendants). AppKit's own structure is out
of scope for this one check: an alert's framework-managed image, text and button nodes, the
window's field editor and its helpers while a field is edited, and any descendant whose
class is a private framework class. Those are printed as one INFO line per surface with a
count and class names, and never fail. The geometry checks and the constraint-conflict log
check still apply to everything, framework nodes included. Two controls keep the scoping
honest: an app-supplied accessory with a deliberately under-constrained view fails check 3,
and the same alert without it passes with the INFO line present.

## Modal sites

34 sites call `runModal()`, which blocks the harness. Do not rewrite production
presentation to suit the test. For each such site that is class A, split building the
surface from running it (a small factory the production path calls unchanged), so the
harness can build and inspect it and drive its buttons. Class B modal alerts are covered
by the generic check and need no change. List any site left uncovered, with the reason.

## Safety

- Everything runs over the isolated demo workspace or a scratch folder, under the
  layout-matrix isolation rules. Never the real home folder.
- A destructive surface is only ever cancelled, unless the confirm path is the thing under
  test and its target is a fixture the harness created.
- No network, no Keychain, no real Trash: use the same interception the existing suites
  use. Open and save panels are dismissed without choosing anything outside the scratch
  folder.

## Controls

- Reuse `PATHEM_LAYOUT_MATRIX_INJECT=accessory-short`: the Rename sheet must fail check 1.
- Reuse the existing dismiss-failure injection (`PATHEM_TRANSIENT_INJECT_DISMISS_FAILURE`):
  check 7 must fail.
- Add one injection that leaves a second window behind on dismissal (check 8 must fail) and
  one that makes cancel commit its edit (check 5 must fail).
- Predicate controls for each new check, in the harness, as in the layout matrix.

## Validation before the full run

Unit 1: the inventory with its new-site gate, the harness, the controls, and exactly three
class A surfaces (the Rename sheet, the Reclaim Space "Delete Now" confirmation, the
conflict popover) plus the generic class B check on ten alerts. Then stop and post a
verdict per criterion. The design is broken if an injection leaves its check green, if a
predicate control fails a check that is not its own, or if the inventory's count of sites
disagrees with a manual count of one file chosen by the reviewer.

Unit 2: all class A surfaces and the full class B set. Real defects are handled as in the
layout matrix: never loosen a check, fix in a separate commit when the mechanism is clear,
otherwise record a known finding with an ID.

## Delivery

`PATHEM_TRANSIENT_SURFACES_TEST=1`, a scenario in `test/e2e/run.sh` through the
known-findings gate, with receipts and an in-process render of each failing surface.

## Out of scope

Pixel appearance (task 1), the main window's layout (task 2, done), tooltips beyond
checking that each class A control with an icon-only face has one.
