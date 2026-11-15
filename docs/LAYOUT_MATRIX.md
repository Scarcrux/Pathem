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

## Launch isolation (added 2026-11-15, answering the implementing lane)

The implementing lane found three ways a matrix launch could touch state it does not own.
All three are accepted as part of Unit 1, in their own first commit, before the harness:

1. Demo root. `DemoWorkspace.build()` deletes and recreates one fixed folder
   (`<temp>/Pathem-Demo`), so two launches, or a harness and an app the owner has in demo
   mode, share and destroy each other's tree. Add a root parameter: automation launches
   pass a unique folder (for example from `PATHEM_DEMO_ROOT`, refused unless it is inside
   the system temporary directory) and remove it on exit. The interactive default stays as
   it is.
2. Preferences. A launch with any automation flag must not read or write the window-frame
   autosave, and the matrix must leave `UserDefaults` as it found it: capture the keys it
   can change (`pathem.terminalVisible` and any panel-visibility key it toggles), and
   restore them before exit, including on a failing run. Prefer not writing at all where a
   small guard on `isAutomationLaunch` does it. An unbundled debug binary uses its own
   defaults domain, not the installed app's, but harness runs still must not leak into
   each other.
3. Guard list. Add `PATHEM_LAYOUT_MATRIX_TEST` to the configuration-root refusal guards in
   `test/e2e/run.sh`, so it refuses to run without a scratch `PATHEM_CONFIG_DIR`.

Evidence each holds: a check that the demo root used is the unique one and is gone after
exit; a before/after dump of the defaults keys showing no change; the guard scenario
refusing the flag without a config directory.

## Findings

### F5 Column repair: selection resolved before baseline creation

Column tag delivery now updates only existing visible name cells using the same
render routine as cell creation. Off-screen rows read the new cache when reused.
No table reload, programmatic reselect, scroll, drill or preview rebuild occurs.
The red-first22 setup losses and gallery-to-column losses are retained above.

The repaired134-cell run passes every setup, selection and viewport assertion:
1184/1192 native exit1 in68.680sec. Exactly eight accepted geometry failures
remain: F1b custom sidebar check8 x2, F4 Gallery paired drawers check4 x2,
F6 Column paired drawers checks2/4 x2. All134 cell receipts report zero pane
selection callbacks during decoration updates; no decoration selection,
viewport or structural effect is recorded. Both actual Gallery preview-follow
probes pass. Evidence: `.build/layout-f5-column-regression.log`, private root
`pathem-matrix-clean-swafjjtd`. Build0, zero new warnings,15 controls pass,
owner defaults unchanged and unique demo removed. This resolves F5 and permits
creating the exact known-findings baseline; it does not waive the eight red
geometry checks. Normal hooks and remaining gates are reported separately.

Per-cell fresh pane/listing/tag baselines raise the original approximately25sec
run to approximately70sec. That is an intentional isolation cost inside the
240sec budget, not a claim that the older order-dependent instrument was better.

### Gallery repair criteria, registered before execution

Coordinator independently confirmed the two icon-to-gallery failures after the
Icon repair and authorized a separate Gallery fix. Update existing filmstrip
labels using the Icon name-render routine, without reloading items or Quick Look.
Gallery decoration snapshots must preserve selection, first visible item, exact
filmstrip origin, preview target/name and actual QuickLookPreview.show call count,
with zero pane selection callbacks. In both view-cycle cells, after tag delivery,
select a different file and verify selection and actual preview target follow it,
with a positive show-call increment, then restore Big Sur and verify its preview.
The callback count and preview-call instruments therefore have real positive
delivery controls. Keep the two original Gallery red receipts and the failed
reloadItems attempt; do not baseline unresolved selection failures.

Gallery repair receipt:134 cells,1138/1170 native exit1 in68.877sec, retained
in `.build/layout-f5-gallery-regression.log` and private root
`pathem-matrix-clean-0n98i72d`. Gallery no longer clears selection; both view
cycles now first lose it on gallery-to-column. Both actual preview-follow probes
pass. Decoration snapshots record unchanged preview target/name and show-call
count, unchanged filmstrip offset and zero pane callbacks; no decoration-effect
line is present. Check7 passes in both view cycles. Column setup/selection losses
remain red for the next separate repair, so check6 is not claimed green yet.
Preferences unchanged, demo removed,15 controls pass. Build0 and warning check
passes with zero new warnings (three known sites). No baseline or land.

### F5 Icon repair and newly exposed Gallery evidence

The proposed visible-item `reloadItems` repair was refuted by its real run:
1131/1170 native exit1,77.254sec, with both list-to-icon losses still present and
seven viewport failures. Retained in `.build/layout-f5-icon-regression.log`;
it is not the final repair. Updating existing visible labels directly avoids any
collection reload, thumbnail request or item replacement. The shared name-render
routine keeps its existing font, alignment, rule, hover, tag and git formatting;
the tag-grouped structural branch is unchanged.

The direct-label run has no Icon selection loss or decoration viewport/structure
effect and zero decoration pane callbacks:134 cells,1138/1170 native exit1 in
70.174sec. Both view cycles now first lose selection on icon-to-gallery instead,
with actual `gallery-tag-reload before=["Big Sur Coast.jpg"] after=[]` receipts.
That is new direct Gallery evidence, not a green view-cycle result or permission
to change Gallery. Column's22 setup failures remain for its separate repair.
Evidence: `.build/layout-f5-icon-direct-regression.log`, private root
`pathem-matrix-clean-11vkaw6_`. Preferences unchanged, demo removed,15 controls
pass. No known-findings baseline exists until selection is fully resolved.

### F5 repair criteria, registered before the instrument run

Coordinator accepted F5 after independently comparing the three32-pair failing
sets. Repair Icon and Column in separate commits. Keep Gallery unchanged and
preserve tag-grouped Icon's existing structural path. Prefer updating visible
decorations over a full data reload. Before each cosmetic callback, capture
selection, first visible item, exact scroll origins and the count of callbacks
actually delivered to PaneController. Column also captures column identities,
active column, navigation generations and preview identity. After the callback,
require identical selection/viewport/structure and zero pane selection callbacks.
Aggregate these receipts into check6 and check7 for the cell. View-cycle check7
exempts intentional mode navigation only; it still checks each decoration update.

Red control: run the real matrix with this instrument and the original raw
reloads, retaining any selection/viewport/callback side effects. After each view
repair, its previously failing cells must stop losing selection, with no viewport
movement or structural/preview mutation. After both, expect exactly eight failing
pairs: F1b custom-sidebar check8 in both appearances, F4 Gallery terminal+torrent
check4 in both, F6 Column terminal+torrent checks2/4 in both. F6 is an accepted
known finding, no repair now. Only then create the exact known-findings baseline,
run three times plus the three injection controls and affected existing suites.
Coordinator now permits one make ci after those checks, but no Unit2 land.

Instrument red control:134 cells,1120/1170 native exit1 in the retained
`.build/layout-f5-instrument-red.log`. The existing22 setup, two view-cycle
selection and eight accepted geometry failures remain; the new per-decoration
viewport assertion additionally fails18 cells while raw Icon reload temporarily
empties the visible items. Actual pane callback counter observes553 callbacks
over setup/navigation (positive delivery control), with zero during cosmetic
reloads. This proves that raw reload can silently clear native selection without
a pane callback. Build0 after explicitly capturing the main-actor counter rather
than an invalid nonisolated property default; the original compile failure is
retained in `layout-f5-instrument-build.log`. No production F5 repair yet.
Comparator controls9/9, preference-retention controls2/2 and completion/capture
controls17/17 pass. The first direct completion-control invocation was refused
for selecting Swiftly; the corrected invocation explicitly selects Xcode Swift.

### Review repair F3: empty Drop Stack allocation

The populated-state control convicted the empty allocation: the same scroll view
had height0 with no chips and height20 with a chip, while its empty hint needed
14pt. Give the scroll view a20pt minimum, preserving the populated minimum and
the existing72pt bar. No geometry check, tolerance or text metric changes.

Three frozen full134-cell runs each passed all28 Drop Stack containment/text
checks (empty and populated) and all14 F2 compact-header containment checks.
All15 predicate controls passed each time. Full native results remain RED:
1137/1169 exit1 in71.432,74.442 and77.028sec. The exact failing set is identical
across all three runs (32 pairs, intersection=union); this is focused F3/F2
verification, not full-suite acceptance. The22 Column setup-selection failures
and two own view-cycle selection failures remain unresolved and unbaselined.

Build exited0 under the shared lock; all native launches were caffeinated and
locked. Display readback5120x1440, unchanged. Each run confirms unchanged
in-memory owner defaults, removed unique demo, actual Home/Photos breadcrumbs,
real tag-cache delivery, no torrent daemon and no constraint conflicts. Evidence:
`.build/layout-review-determinism-{1,2,3}.log`, private roots
`pathem-matrix-clean-a0ifpt9k`, `pathem-matrix-clean-q1aupii5`, and
`pathem-matrix-clean-x46pva82`. The Gallery paired-drawer render was inspected:
actual Home/Photos and native left tag dots are present. Original F3 red receipts
and renders are retained. No make ci, Unit2 land, install, deployment or display
change. Ordinary commit-hook results are reported separately.

### Review repair F2: compact section-header labels

The accepted F2 mechanism is a section-header NSTextField left unhidden when its
parent row deliberately shrinks to6pt. The header factory now sets `isHidden`
from `showsLabels` on every reuse, restoring visibility when expanded. No row
height or geometry predicate changed. Original receipts in
`layout-review-red-before-fixes.log` and `layout-review-fresh-before-fixes.log`
are retained red. After the one-line repair, all14 compact/custom-sidebar
check2 receipts pass in the134-cell run. This is a focused F2 PASS, not full
suite acceptance: native exit1 at1115/1169 in76.957sec, with other open findings
retained. Evidence: `.build/layout-f2-regression.log`, private run
`pathem-matrix-clean-vy_bn7_l`. Build exited0 under the shared lock; native run
was caffeinated/locked. The same run records empty Drop Stack area0pt versus
populated20pt in dark appearance, convicting the missing empty-state allocation
before an F3 repair. Ordinary commit hook outcomes are reported separately.

### Unit 2 review revision, criteria before rerunning

Coordinator review rejects the unreachable sidebar-hidden axis and the inherited
global selection anchor. Drop all12 sidebar-hidden cells, explicitly recording
that drop. Reset panels, pane listings/modes, sidebar200pt, ratio and selection
before every cell. Select only after actual listing and metadata delivery; then
compare selection through that cell's own transition, never against a prior cell.
Add two deliberate250pt compact-sidebar round trips (F1b), two populated Drop
Stack cells, two view-cycle cells and one resize-cycle cell:134 cells, preserving
the earlier pairs and size/view/light axes, still under150 and240 seconds.
The custom width is staged by the split position within its delegate limits.

Before any known-findings baseline is created, run the final no-injection set
three times. Report exact failing-set intersection/differences and each actual
selection-loss transition. No correlated inherited selection failures may be
baselined. The eventual exact cell/check/ID baseline must reject both new and
stale failures. Keep native exit1 as native RED even if the separate baseline
comparison succeeds. Coordinator authorizes F2 and a convicted F3 repair only,
each in its own commit. F1b and F4 stay open; no speculative production repair.
Presentation acceptance requires actual Home/Photos breadcrumb labels and real
tag-cache delivery (not injected tag data) before selection/capture.

### Unit 2 covering set, registered before execution

Unit 1 was independently rerun and accepted by the coordinator, authorizing its
land and Unit 2. Full runs cover 139 cells: 15 dark size/view baselines; 35 dark
default-size view/panel combinations; 14 dark minimum/wide list/panel cells;
10 dark default-size view/panel-pair cells; four dark matching non-list panes;
two dark non-even list ratios; all 56 default-size cells repeated in light;
and three explicit list resize transitions (minimum, wide, default). Every
panel cell includes an on/off transition and restoration checks. Default-size
view baselines traverse all five modes and back. This is a covering set, not
the cross product. No panel pair or axis is dropped initially.

Acceptance remains fewer than 150 cells and less than 240 seconds per native
launch, including controls. The bounded runner must report cell count, native
exit, elapsed wall time, all findings, and the three independently delivered
regressions. The existing three-cell mode remains the small instrument check.
Unknown real failures remain red and are reported with render paths; no check
or tolerance is relaxed to admit the covering set. Preference snapshots stay
in memory and are written mode0600 only on differences. Passing clean runs
remove their own scratch tree. Red runs retain their log and renders, but never
write matching owner defaults to disk. Torrent geometry uses demo rows and a
detail staging hook without daemon/network activity; it does not test transport.

### Unit 2 end-to-end receipt: instrument ready, product gate RED

Unit 1 landed normally at `ea0843b`, with the pool workbench retained. Unit 2
implements the 139-cell set above and wires the clean driver into
`test/e2e/run.sh`. This scenario alone gets a 245-second outer bound; its native
child is bounded to 240 seconds. Other scenarios retain their 120-second bound.
No full `make ci` was run and Unit 2 is NOT landed pending coordinator review.

Final source was built under the shared lock; all following native runs used
`caffeinate -d -i` and the same shared lock. Display readback stayed 5120x1440.

| Full case | Cells | Native wall seconds | Native result | Driver exit |
|---|---:|---:|---|---:|
| No injection | 139 | 24.434 | FAIL 1090/1239, exit1 | 1 |
| terminal-collapse | 139 | 25.273 | FAIL 992/1239, exit1 | 0, expected regression observed |
| icon-label-short | 139 | 23.739 | FAIL 1048/1239, exit1 | 0, expected regression observed |
| accessory-short | 139 | 26.440 | FAIL 1037/1239, exit1 | 0, expected regression observed |

All runs delivered all 15 predicate controls, all 139 unique cells and all
planned axes/pairs. No cells were dropped, no check tolerance changed and no
red cell was skipped. Each `(cell, check)` has exactly one PASS/FAIL receipt;
geometry failures report the count and the first offending class/id/frame.
Each injection emits one delivery receipt. The no-injection run explicitly
passes the three targeted assertions that the respective injection fails:
`default-list-terminal-dark check1`, `default-icon-none-dark check4`, and
`rename-initial-control check2`. This comparison was checked against the raw
logs; an already-red unrelated cell is not used to claim discrimination.

All four runs preserved both complete defaults domains in memory, removed their
unique demo roots on exit, and confirmed no torrent daemon was running. Matching
defaults dumps were absent on disk. No-injection remains a failed native/driver
gate, not a passing suite. Injection-driver zero means only that its intended
negative control was observed; those native failures and unrelated findings
remain unchanged. No constraint-conflict logs were present.

#### Open findings, not fixed or waived

| ID | Receipt and observation | Confidence / next boundary |
|---|---|---|
| LM2-F1 | `minimum-list-sidebar-hidden-dark check8`: sidebar131pt before versus111pt after; compact restoration may return200pt rather than prior width. Twenty-five check8 failures in the final clean run. | Allocated-frame drift observed. Hidden-sidebar is a direct split fixture, not an exposed app command. Some compact/pair failures follow that earlier drift; independent product mechanisms remain for triage. |
| LM2-F2 | `default-list-compact-sidebar-dark check2`: four NSTextFields at(2,-4,25,14) inside6pt cells. | Structural containment violation. Render shows fitting icons; empty/section-header labels may be intentionally collapsed. Do not claim visible clipping without semantic triage. |
| LM2-F3 | `default-list-drop-stack-dark check2/check4`: empty text179x16 allocated in a630x0 NSScrollView, measured text needs14pt. | Out-of-bounds allocation observed. Render still shows the empty text; pixel clipping is not proven. All 12 tested Drop Stack cells remain red. |
| LM2-F4 | `default-gallery-terminal+torrent-dark check4`: two preview-name fields have zero height, e.g.(14,147,421,0), need16pt; corresponding light case also fails. | Zero-height allocated labels observed with the two drawers. Mechanism not yet convicted. |
| LM2-F5 | First final clean selection failure: `wide-icon-none-dark check6`, incoming left/Tromsø Aurora.jpg + right/Lofoten Dawn.jpg; setup loses the left name. Eighty-six downstream check6 failures retain the global anchor. | The earlier full run first lost selection at a different cell. Before/setup/shown/restored names are now recorded. These correlated failures are not86 independent bugs, nor attributed to an injection or timing cause. |

The final clean run has149 failed assertions: check2=24, check4=14, check6=86,
check8=25; no check0/1/3/5/7 failures. LM2-F1 through LM2-F5 were posted separately
on the Pathem board with raw receipts and representative renders before any fix.
No new production behavior repair is included in this unit.

Evidence: `.build/layout-unit2-final-{clean,terminal-collapse,icon-label-short,accessory-short}.log`.
These logs name their retained private directories:
`pathem-matrix-clean-malssmpr`, `pathem-matrix-terminal-collapse-kf332dgj`,
`pathem-matrix-icon-label-short-jq9wxwvg`, and
`pathem-matrix-accessory-short-dx67ajqr`. Earlier full receipt
`pathem-matrix-clean-hpuxfx3m` is retained:139 cells,44.270sec,1104/1238, exit1.
Its representative compact, Drop Stack and Gallery-pair captures were inspected.
Later instrumentation only adds selection-phase names, once-per-injection
delivery, and no-daemon attestation; it does not repair any red cell.

Privacy follow-up: owner preference exports now stay in memory. Only a mismatch
writes before/after evidence (mode0600, under0700 scratch); two synthetic tests
discriminate matching/no-files versus different/private-files behavior. Native
passing runs delete their exact owned scratch. Failing native runs keep logs and
renders but do not dump matching preferences, including expected injection-red
runs. Thirty-two historical preference snapshot files from this lane's exact
owned Unit 1 artifacts were deleted; geometry logs/renders remain. Historical
statements below describe the original runs, not current retention.

Additional checks: the revised three-cell sample passed45/45 and removed its
passing scratch; isolation probe passed and removed its scratch; support tests
2/2, E2E completion/capture-policy controls17/17, shell syntax, Python compilation
and `git diff --check` passed. Full product E2E, packaged E2E, Release build,
installation, deployment and display-mode changes were NOT RUN. Ordinary commit
hook results are reported separately. READY means reviewable instrument and
open findings, not a green release gate or permission to land.

### Unit 1 isolation prerequisite

The isolated automation demo now uses a new directory, rejects existing and
non-temporary roots before creating AppKit state, and removes its tree at normal
process exit. Interactive demo behavior is unchanged. All automation skips window
frame restoration/autosave and terminal visibility/tooltip defaults writes.
The matrix flag is included in the configuration-root guard and its E2E probes.

Verification: `make build` under the shared lock exited 0. The bounded
`test/layout_matrix_isolation.py` real launch exited 0: two unsafe demo-root
refusals, two config-root refusals, a unique root used and removed, an actual
terminal site-shot capture, and complete before/after exports of both `Pathem`
and `com.scarcrux.pathem` defaults domains unchanged. The capture was inspected.
Run with `caffeinate -d -i` under the shared lock; display readback was 5120x1440,
no mode change. Private evidence directory: `pathem-matrix-isolation-suu02g4k`.
Two earlier instrument failures are retained: the guard launch selected Swiftly
instead of Xcode (fixed by selecting Xcode's PATH), and `/var` versus
`/private/var` receipt spelling (fixed by resolving both paths before comparison).
Neither is claimed as a product failure. Abrupt termination such as SIGKILL cannot
run an exit handler; the runner retains its private scratch on failure.

### Unit 1 three-cell validation verdict

Implemented on the private codex-2 branch following isolation commit `a436a80`.
No full-matrix expansion, application install, site deployment, display change,
or land is authorized by this receipt. Full E2E scenario admission is Unit 2;
the matrix configuration-root refusal probes are already wired in Unit 1.

Run the bounded sample with the shared native lock and awake-display assertion:

```
caffeinate -d -i lockf -k /tmp/commandem-swift-build.lock \
  python3 test/layout_matrix_sample.py clean
```

Replace `clean` with each injection name for the regression controls. Each launch
contains exactly `default-list`, `default-icon`, and `default-list-terminal`, all
at 1100x700 in dark appearance. The initial Rename sheet is an additional
regression control, not a fourth browser cell or a full dialog matrix. It uses
the production Rename factory and compares the suggestion button against the
accessory's allocated bounds before pumping the next event-loop turn.

| Criterion | Actual final evidence | Verdict |
|---|---|---|
| Predicate controls discriminate | All 15 pass in each launch: known-good/restored tree; collapsed region, outside control, overlapping siblings and short label each fail only their named predicate; real under-constrained region fails check 5 then passes with the missing position constraint; positive/negative selection, viewport and reversibility; plain/decorated single-line truncation and too-short counterparts | PASS |
| Clean three cells | Native exit 0, 45/45; geometry checks 1-5 in each cell; both panes' selection and first visible entry survive the applicable transitions; panel frames restore within 2pt | PASS |
| Terminal collapse injection | Native exit 1, 41/48; actual skipped adjustSubviews receipt; terminal cell fails check 1 (including 0pt sidebar/terminal), plus check 7 and restored checks 7/8 | PASS, expected native RED |
| Icon label injection | Native exit 1, 43/69; original point-size allocation receipt; icon cell fails checks 2 and 4 for 13 labels, 32pt labels extend 4pt outside their 92pt cells | PASS, expected native RED |
| Accessory injection | Native exit 1, 44/45; attached-remeasurement skip receipts; initial Rename fails check 2, accessory 71pt versus clean 74pt | PASS, expected native RED |
| Constraint log check | No constraint-conflict lines in the merged process streams, including startup/sheet presentation; actual ambiguity control separately discriminates check 5 | PASS |
| Launch isolation on all four final runs | Complete defaults-domain exports unchanged; unique demo removed even on native exit 1; exactly three browser-cell receipts per run | PASS |

The Python driver's exit 0 for an injection means the expected red result was
observed, not that the native application passed. Raw native exits and logs are
retained. View-switch viewport checks are explicitly EXEMPT by contract; no
other skipped matrix assertion is claimed. No new product layout defect was
convicted by the final clean three-cell sample.

Final evidence directories under system temporary storage (private, mode 0700):
`pathem-matrix-clean-79yomixi`, `pathem-matrix-terminal-collapse-a1u0tddo`,
`pathem-matrix-icon-label-short-h_y6nhy9`,
`pathem-matrix-accessory-short-ue16lyfg`. Each contains `native.log`, complete
before/after defaults dumps, and actual window PNGs. Failed checks write named
captures; the Rename failure also captures its own sheet. Clean terminal, red
icon and red Rename captures were inspected. These in-process renders are for
geometry evidence only, not approval of material/pixel fidelity.

Instrument corrections, with original failures retained: first harness build
failed on an inferred NSClipView-only array, corrected to NSView. Demo tabs are
opened asynchronously, so startup awaits tab delivery; navigation awaits the
actual requested entry, not merely a changed URL with the old entry count.
The ambiguity control now lives in a native window with width/height/leading
constraints and no vertical position; adding the missing top constraint really
restores it. An unbounded-height NSTextFieldCell measurement falsely requested
32pt for single-line truncating attributed table names with wraps=false, even
on a copied cell set to single-line mode. The contract explicitly permits their
horizontal truncation: these use attributed one-line font/attachment metrics;
wrapped icon labels retain width-constrained cell measurement, intersected with
their parent's allocated vertical area. Four plain/decorated good/short controls
discriminate that policy; no tolerance was increased or failing product cell
skipped. Earlier receipts include `pathem-matrix-clean-tziuex8c`,
`pathem-matrix-clean-5p1ex5lm`, and `pathem-matrix-clean-0u1z42ts`.

Final debug build exited 0 under the shared lock. Python compilation and
`git diff --check` passed. Full matrix, full product E2E, packaged E2E and Release
build are NOT RUN for this sample-only unit. Ordinary commit hook results are
reported separately on the board. Unit 2 waits for coordinator acknowledgment.

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
