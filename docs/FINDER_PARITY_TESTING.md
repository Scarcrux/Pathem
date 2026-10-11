# Finder context-menu parity: Mission 53 acceptance

Trigger: the owner reported missing Finder actions, notably Compress. Inspection found
working commands for compression, alias creation, original reveal, and Quick Look,
but none were exposed by the shared context menu. Show Package Contents had no command.

Before running the sample, require:

- All five real pane views expose the new actions through their actual shared menus.
- A package selection exposes Show Package Contents; an ordinary directory and mixed
  selection do not. Executing the action browses its Contents without launching the app.
- A real alias/symlink exposes Show Original; an ordinary file does not. Execution reveals
  and selects the target, including when it is in another directory.
- Compression and alias creation operate on disposable real files, preserve source bytes,
  and select the created item after asynchronous enumeration. ZIP and 7z both count.
- Empty selections hide selection-only additions. Visible separators are never leading,
  trailing, or adjacent. Saved ordering and hidden-item customization still work.
- Every new entry has a usable title and icon; disabled commands refuse unsupported
  selections. Tests dispatch the real menu action through the responder chain.
- Gallery filmstrip geometry must leave more vertical space than its item height plus
  top/bottom insets, including legacy horizontal-scroller space, at minimum/default/wide
  window sizes. An AppKit invalid-flow-layout warning or insufficient measured clip height
  fails; checking only the outer scroll-view frame cannot discriminate this defect.
- Switching panes or navigating away during compression must not steal the active pane,
  selection, or navigation. The originating pane selects its archive only while still
  showing the original folder.

The ordinary-file/directory and empty/mixed-selection cases are negative controls: a
menu which always shows the actions fails. Selection of the original source after a
creation is a failure, even if an archive/alias exists. A missing menu in any view fails.
Run the targeted real-window sample before the full local CI suite. Log every criterion,
including failures and corrections, below. No installed application, user files, keychain,
provider accounts, or public publication are involved.

Scope limits: menu construction, validation, responder routing, filesystem results, and
viewport geometry are deterministic. Native popup raster appearance, physical gestures,
Quick Look rendering by external services, iCloud, Services/Quick Actions, and physical
volume ejection remain separate environmental/visual acceptance boundaries.

Instrument validation: initial samples correctly failed controls, but macOS denied the
background process activation (`key=false`, `routed=false`). Application-wide nil-target
dispatch therefore tested absence of a key window, not contextual command correctness.
The accepted instrument walks and validates the actual window responder chain and uses
its first responder's `tryToPerform` to route unchanged menu actions. No explicit browser
target is substituted. All view swaps wait for the actual content mode, not the desired
persisted format. URL paths, not directory-hint-sensitive URL equality, identify navigation.
Entering the harness from a main-queue callback was also rejected: nested RunLoop pumping
cannot re-enter that queue to finish async listings. No product fix was inferred from these
instrument failures.

Validated sample: all real-menu capability/negative controls and responder routing passed.
Package navigation and external symlink reveal passed. Actual alias and ZIP/7z creation
and byte-preserving extraction passed, but all three created-item selection controls failed:
the pane still selected `source.txt`. Mechanism: creation called `select` immediately
after starting off-main enumeration, while the new row was absent. The fix queues selection
before reloading and reveals it after enumeration. Async compression captures its originating
pane and checks the original folder before queuing selection; it must not select in whichever
pane happens to be active at completion.

Geometry sample: all three sizes measured filmstrip outer height 124pt but actual clip height
109pt, below the 120pt item-plus-insets requirement; the instrument failed all three cases.
The 15pt legacy horizontal scroller explains the deficit. Gallery now derives its row height
from item height, insets, legacy-scroller width, and 4pt safety space. The regression matrix
checks both legacy and overlay scrollers at all three sizes, rather than assuming the user's
scrollbar preference. Pane-switch and navigate-away archive controls passed after the queued
origin-pane selection change.

Acceptance sample: **131/131 PASS** on 2026-10-11 after the fixes. Per-criterion verdicts:

- Five-view actual-menu entries, titles, icons, enabled states: PASS.
- Package positive plus ordinary-directory/mixed/empty negative controls and browsing: PASS.
- Symlink and real alias positive plus ordinary-file negative controls, target reveal: PASS.
- Real alias/ZIP/7z creation, deferred selection/visibility, extracted/source bytes: PASS.
- Empty-command refusal, separator cleanup, custom order and hidden-item preservation: PASS.
- Real-window responder-chain validation and action delivery: PASS; application-wide key-window
  activation and physical native menu gestures are explicitly not covered on this host.
- Six gallery size/style combinations: PASS, legacy clip 124pt and overlay clip 139pt,
  each exceeding the measured 120pt requirement. No invalid-flow-layout warning in this run.
- Pane-switch and navigate-away completion controls: PASS.

The initial sample's red controls show that the instrument detects both premature selection
and inadequate gallery clip height. Full local CI is the next acceptance gate, not a substitute
for these discriminating controls. The new Finder UI scenario is mandatory in debug E2E.

Gate correction: the first full CI attempt passed engine tests and 19/19 debug scenarios,
but the release compiler rejected a late File-menu placement edit because its input changed
during compilation. The added top-level File-menu check also initially shadowed the helper
named `fileMenu`, causing a debug compile error; renamed the local binding. Neither failed
attempt counts as full acceptance. Rebuild and rerun the full gate against frozen source.

Final frozen-source gate on 2026-10-11: `make ci` exited 0. All 15 XCTest cases and 766
Swift Testing cases in 160 suites passed; debug E2E 19/19 (existing UI 49/49, search UI
39/39, Finder UI **132/132**); packaged E2E 9/9 including signature verification, launch,
and a visible release window. The independent German real-window run also passed 132/132.
The extra criterion verifies Show Package Contents is directly discoverable beside Open
in the File menu, not buried under Make Link.

Mission 53 remains `now`. Core parity task `t-0dab798d` and gallery geometry task
`t-54bc808a` are complete; the broad parity and layout/visual/environmental tasks remain
open. Full CI still emits existing compiler/toolchain warnings; this slice does not claim
warning cleanup or native popup visual approval. No installation/restart, public release,
provider credentials, or keychain changes were performed.
