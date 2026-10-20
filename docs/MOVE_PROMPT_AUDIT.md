# All four move-prompt paths — 2026-10-20

Trigger: owner cannot identify the exact unwanted prompt and requested checking
all four candidates. Audited source: `34bb79b`. No production fix or installation
is included. This follows `LIVE_FILE_OPERATION_DIAGNOSIS.md`; viewport Task 53.47
and existing popover intermittent Task 53.36 remain open.

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
