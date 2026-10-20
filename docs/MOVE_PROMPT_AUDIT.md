# All four move-prompt paths — 2026-10-20

Trigger: owner cannot identify the exact unwanted prompt and requested checking
all four candidates. Initial audited source: `34bb79b`; the initial audit below
changed no production behavior. The later approved implementation and validation
are recorded at the end. This follows `LIVE_FILE_OPERATION_DIAGNOSIS.md`.
The separate popover intermittent Task 53.36 remains open.

## Results

| Surface | Trigger and batch behavior | Confirmed gap |
| --- | --- | --- |
| Move Here / Copy Here menu | List receives a drop onto a different file. Menu uses all dragged URLs. | A neighboring file in the same source folder still qualifies although ordinary same-folder drops are filtered as no-ops. The menu can then initiate a conflict with the source itself. No physical-intent claim. |
| Replace / Keep Both / Skip | A submitted transfer has collisions; one choice already applies to every URL in that transfer. | Labels do not explain batch scope. Confirmation is outside `transferInFlight`, so identical pending requests are not deduplicated. |
| Downloads filing suggestion | An ordinary browser window sees a newly present filename and gets a confident move suggestion. One suggestion is shown at a time. | No startup opt-in gate, no shared ownership across windows, no current/pending URL deduplication, and no batch acceptance/dismissal surface. |
| Move selected items to Trash | Local selection with confirmation enabled; one answer already covers the entire selection. | Repeated requests independently enter confirmation and replace the earlier pending request; there is no batch-admission guard. |

## Bounded checks and confidence

Criteria were written first in `/tmp/pathem-prompt-audit.LzGkE3/CRITERIA.md`.
All three new diagnostic compilations and executables exit 0 naturally. The
previous conflict-admission executable was also rerun and gave the same receipts.
Exit 0 means the instrument ran, not that every desired product invariant passed.

These are headless exact-method/algorithm probes with explicit fake boundaries,
not native-window, physical drag, OS-watcher or owner-symptom reproductions. They
do not bypass the previously refused owner-app computer-use access. The production
files are unchanged. Fixture files live only under the disposable study root.

### File-on-file target and no-op filtering

Compile current `fileRow` and `incomingURLs` helper bodies unchanged, with a simple
row model and Foundation path handling. Self-file and folder controls reject file
targets; a genuinely incoming file qualifies. The same-folder neighbor differs:

```
DROP_SELF incoming=0 fileTarget=nil
DROP_FOLDER incoming=0 fileTarget=nil
DROP_EXTERNAL incoming=1 fileTarget=b.txt
DROP_SAME_FOLDER_NEIGHBOR incoming=0 fileTarget=b.txt
```

The actual `FileListController.acceptDrop` chooses that file-target branch before
the ordinary incoming-URL filter. `dropMoveHere` forwards the URLs to `dropFiles`,
whose containment filter does not exclude sources already in the destination.
Its existence check therefore counts the source itself as a conflict. The engine
has a separate self-transfer backstop: Replace/Skip skip it; Keep Both can create
a duplicate. Do not remove that data-safety backstop. The List micro-drag guard
rejects only local travel below 12 points and is not a general intent classifier.

### Conflict admission

Exact unchanged `resolveThenTransfer`, with a gated fake confirmation provider and
no-I/O transfer recorder, retains the previous result:

```
SINGLE asks=1 pending=1 transferInFlight=false
REPEATED secondAdmitted=true asks=2 pending=2 transferInFlight=false
NO_CONFLICT asks=0 runs=1
PRESET asks=0 runs=1
```

Single/no-conflict/preset controls PASS. One-pending-request admission invariant
FAILS. The independent test continuations are both cancelled; this is not a claim
that production shows two simultaneous popovers. Production CursorConfirm replaces
its pending prompt and resumes the old one as Cancel rather than deduplicating it.

### Downloads queue

Compile the current controller algorithm with only its imports replaced by local
headless models. Fake bar/watcher/planner/feedback/mutation boundaries isolate
queue ownership from native UI, OS delivery and filing prediction. The real
directory-name snapshots and `didChange`, `showNext`, `dismiss` bodies are used.
The planner offers valid fixture PDFs only; no real filing prediction is claimed.

```
EXISTING current=nil pending=[]
ARRIVALS current=a.pdf pending=["b.pdf"]
TWO_WINDOWS first=a.pdf second=a.pdf
REAPPEAR current=a.pdf pending=["b.pdf", "a.pdf"]
DISMISS_ONE current=b.pdf pending=["a.pdf"]
DISMISS_TWO current=a.pdf pending=[]
DRAINED current=nil pending=[]
```

Seeded-existing, hidden/partial exclusion and one-at-a-time/drain controls PASS.
Shared-notification ownership and current/pending URL deduplication expectations
FAIL. The absent/reappeared snapshots are explicitly delivered by temporarily
moving one fixture out and back. This establishes what happens IF both snapshots
arrive, not that a particular editor/OS save delivers them. No Move action is
invoked; mutation stubs trap if unexpectedly reached. Each ordinary browser
window starting its own controller/watcher is separately source-confirmed.

### Trash

Compile unchanged `trashSelection` with fake pane/view/confirmer boundaries and
a no-I/O mutation recorder. The confirmer models production's pending replacement
as Cancel; it does not create a popover or exercise native close timing.

```
TRASH_EMPTY asks=0 batches=0
TRASH_PREF_OFF asks=0 batches=1 items=2
TRASH_CANCEL asks=1 batches=0
TRASH_ACCEPT asks=1 batches=1 items=2
TRASH_REPEAT asks=2 replaced=1 batches=0
REMOTE_PREF_OFF_CANCEL asks=1 operations=0 localBatches=0
```

Empty/off/Cancel/whole-selection acceptance controls PASS. Repeated same-batch
deduplication expectation FAILS. Remote permanent deletion still asks even when
local Trash confirmation is disabled; Cancel produces no provider call. Keep
this safety distinction and do not introduce a blanket Yes-to-all-delete policy.

## Repair boundaries

- Gate optional menus/suggestions by explicit intent/preferences; do not suppress
  real collision or permanent-delete warnings just to hide the symptom.
- Give a logical batch ownership through confirmation and execution; suppress
  duplicate requests but retain Cancel/retry and distinct-request behavior.
- Label conflict and Trash batch scope clearly. Downloads needs its own explicit
  review/batch/dismiss design; accepting one suggestion must not approve later ones.
- For Downloads, consider shared ownership, deduplication and opt-in controls, not
  persistent auto-move permission. No owner preference was changed here.
- Validate actual menu/confirmation event delivery and passive viewport stability
  during the later fixes. This check does not close native appearance/lifecycle,
  background refresh, or any existing intermittent acceptance task.

No application transfer/Trash action, owner-file mutation, owner preference or
clipboard change, debug marker, app restart, installation, permissions grant,
credential access, publication or full CI run. Only one disposable fixture was
temporarily moved out and back to deliver the two directory-name snapshots.
All findings remain pending repairs; this documentation unit is not a shipped fix.

## Approved implementation scope — 2026-10-20

Owner requested design, fixes and tests. Passive List refresh must preserve its
clip offset instead of following re-sorted selection; explicit sort/Reveal still
scrolls. Transfer completion must not force destination scroll. A browser owns
confirmation admission synchronously before scheduling the ask, through Cancel or
execution handoff; another ask must never replace it. Conflict decisions and local
Trash already cover a batch and should say so. Distinct requests while busy are
refused, not silently queued for later destructive execution. Permanent delete
warnings remain mandatory. Option-drop explicitly requests the advanced file menu;
ordinary drops use folder routing and reject same-folder no-ops.

Downloads suggestions become opt-in (legacy absent setting is off). Per-enabled
session, each path is suggested once and only one window can claim it. Stop clears
pending UI/claims; async completion cannot resurrect a stopped session. Dismiss All
clears the current queue without enabling automatic moves or approving future
arrivals. No global Yes-to-all destructive setting is added.

Before broad validation, a bounded native sample must prove pending confirmation
identity/count survives duplicate transfer/Trash requests, Cancel releases it,
ordinary/multi-item controls still work, and passive re-sort holds a nonzero
viewport while explicit Reveal works. Downloads tests must contrast existing,
hidden/partial, ordinary new and absent/reappear arrivals, two controllers, stop
and Dismiss All. Drop tests must contrast ordinary same-folder no-op, incoming
drop, and explicit Option advanced menu. Native checks use private fixtures/config
and pasteboards, not the owner window. Do not change failed assertions or widen
timeouts to obtain a pass. Retain red baseline receipts before production changes.

### Baseline receipts

The first diagnostic build caught a missing `includingHidden` argument in the new
test harness; corrected before any native verdict. First native run was 18/24;
one Option-menu positive control incorrectly inherited the preceding unwanted-menu
count. Correcting that counter to compare its own before/after receipt yields a
repeatable **19/24** baseline. The five red assertions are duplicate-conflict prompt
identity, duplicate-Trash identity, cross-action prompt ownership, passive metadata
viewport retention, and ordinary same-folder no-op drop. Independent batch-copy,
Cancel/retry, intercepted whole-selection Trash, nonzero viewport and actual resort
delivery, explicit Reveal/sort, Option menu and fixture-integrity controls pass.

Baseline logs: `/tmp/pathem-prompt-fixes-baseline-native-2.log`; the earlier red
instrument/build outputs remain under the same prefix. A later patch attempt used
pre-formatting context and was rejected without edits; reapplied with exact current
context. Production changes follow this corrected baseline, not the invalid count.

Treatment sample additionally exercises a real edit begun at the listing-apply
boundary, passive refresh/rename in all five views, a directly competing confirmer,
and actual controller queues/controls for Downloads with private fixtures.

### Treatment and discriminating controls

The first treatment sample was **67/74**, not an acceptance pass. All five rename
checks exposed a separate explicit Reveal callback; Tree refresh lost selection.
Geometry receipts separated a third, instrument-only issue: List retained the
exact clip `(0,1611)`, but equivalent directory URLs differed in representation.
That identity check now compares standardized paths; the clip assertion remains.
Tree retained its clip but selected nothing, so it now restores selection by full
node path after rebuilding rows. Rename and its Undo/Redo select the new identity
after enumeration without invoking Reveal.

A temporary counterfactual reinstated only the old List auto-follow branch. With
the corrected instrument it moved the clip from `1611` to `3277` and failed the
passive-viewport assertion; the treatment retained `1611`. The counterfactual was
removed before the passing build. This validates discrimination rather than
weakening the scroll expectation to match the implementation.

The repaired bounded sample passes **82/82**. The integrated mandatory Sidebar
scenario passes **178/178** (the existing 88 plus 90 operation-stability checks).
Additional controls exercise private-pasteboard Paste admission during a pending
prompt, actual FSEvents from a disposable watched folder, watcher stop, and the
mounted General Settings opt-in/out control. Downloads queue tests also use two
controllers and an actually mounted bar in a 720-point window; all button frames
fit. The five view refresh/rename checks use nonzero clip offsets and delivered
listing receipts; rename Undo/Redo preserves identity and clip. Batch acceptance
copies two real fixture files once; Trash acceptance intercepts the exact selected
fixture snapshot without touching the owner's Trash. Cancel/retry and explicit
sort/Reveal remain independent positive controls.

Evidence logs under `/tmp/pathem-prompt-fixes-`: `treatment-native.log`,
`geometry-native.log`, `counterfactual-native.log`, `final-sample-native.log`, and
`integration-native.log`; all associated build results are retained. Rejected
stale-context patches made no changes. Localization lint passes all six catalogs.
The first full CI was **red**, exit 2: 15 XCTest plus 787 Swift Testing passed;
product 66 PASS / one standing visual SKIP / one FAIL. Package was correctly not
reached. Cached full-output reproduction repeated the older UI suite's 48/49.
Added details without changing its assertion measured a valid inset top offset
`(0,-28)` becoming `(0,0)` during metadata refresh; sort and selection were correct.
This convicted the old manual zero-based clamp, not auto-follow. The repair uses
`NSClipView.constrainBoundsRect` after layout, preserving legal adjusted insets
while still constraining a shrunken listing. The focused treatment build exits 0
(12.68 seconds), older UI **49/49** and Sidebar **178/178** exit 0. The identical
metadata assertion now reports `-28 -> -28`, with delivered resort and selection
unchanged. Fresh full CI is running; no final acceptance or installation is
claimed yet. Receipts: `inset-build.log`, `ui-inset.log`, `inset-stability.log`.

The second full CI was also **red**, exit 2: engine tests passed again; product
66 PASS / one standing visual SKIP / one FAIL. Older UI was 49/49 and Sidebar
178/178, but startup smoke failed. Complete cached reproduction convicted a
regression introduced by the AppKit-only clamp: shrinking a 40-row list to two
returned `875 -> -22`, while the unchanged established shrink assertion requires
zero. That repair was rejected. The revised change retains the original upper
clamp (short listings still return to zero) and uses AppKit only to determine the
legal lower bound for a previously negative inset. Neither the inset-retention
nor shrink assertion is changed. Combined treatment exits 0: startup smoke PASS
with shrink `875 -> 0`, older UI **49/49** with inset `-28 -> -28`, and Sidebar
**178/178**. A fresh full CI run follows this discriminating sample.
Receipts: `ci-second-red.log`, `smoke-repro.log` under the same log prefix.

The older UI suite's Cut/Paste fixtures also used the system clipboard, unlike
the new private-board Sidebar checks. It now uses a unique debug pasteboard and
releases it before exit. Earlier full-CI/reproduction runs could replace the
owner's clipboard; no original clipboard value was saved or restored, and a
newer owner copy must not be overwritten by a speculative restoration. This is
separate from the newly reported Copy-versus-drag metadata discrepancy (53.52):
both Copy entry points write URLs only, whereas drag also advertises legacy
filenames and non-text promises. The receiving app/representation is still
unknown; no exporter change is justified by that source difference alone.

Additional logs: `ci-first-red.log`, `ui-repro.log`, `ui-geometry.log` under the
same `/tmp/pathem-prompt-fixes-` prefix. The geometry run retained the same red
assertion and reports `moved=true`, `visible=false`, selected `opened-00.txt`,
before `-28`, after `0`.

These tests prove the named refresh/admission/menu/queue mechanisms, not physical
third-party dragging, owner-session symptom frequency, native-speaker translation
approval, or the separate intermittent close failure (53.36), first-launch
preferences failure (53.39), or disk-image busy failure (53.42).

### Final verification

The third, normal `make ci SWIFTPM_FLAGS='--build-system native --jobs 2'`
finishes **exit 0** on the lower-bound-only repair:

- 15 XCTest and 787 Swift Testing tests pass.
- Debug product: **67 PASS / one standing transparent-browser-capture SKIP /
  zero FAIL**, including older UI 49/49 and Sidebar 178/178.
- Current-host ARM64 ad-hoc package: **14/14**, including strict signature,
  Hardened Runtime, bundle/helpers/languages, isolated release launch and visible
  window. This is not a universal/distribution/notarization acceptance claim.
- Fresh diagnostic inventories: debug 15 known, release 12 known, **zero new or
  unparsed**; all six localization catalogs pass (1,688 canonical keys).

Final logs are `/tmp/pathem-prompt-fixes-ci.log`,
`/tmp/pathem-prompt-fixes-ci-debug-build.log` and
`/tmp/pathem-prompt-fixes-ci-release-build.log`; the two red CI logs remain intact.
Tasks 53.47–51 are complete for these reproduced mechanisms. Mission 53 stays
`now`; broad visual/environmental acceptance and 53.36/39/42 are not closed.
The new Copy-versus-drag report stays pending as 53.52 until the receiving app and
representation are established. No export-policy fix is claimed for it.
No owner-app installation, restart, publication, credentials or permissions grant.
