# Live file-operation report — 2026-10-20

Trigger: owner still sees viewport/location changes while files are edited or
moved, and repeated/unwanted move prompts with no clear apply-to-all choice.
This session diagnoses and records work; it does not implement a behavior change.

## Installed versus current source

The running process is the installed Pathem app. Its executable SHA256 matches
the previously verified installed-source `32d161a` receipt in Mission 55. No
restart or install occurred. FileListController, PaneTransfers, Downloads suggestion
controller and suggestion startup are unchanged between that source and `4024a18`.
The relevant conflict-prompt/admission logic is also unchanged (formatting and
unrelated Undo/Redo fixes differ). Thus newer search-only work does not explain
away these remaining behaviors as fixed-but-not-installed.

## 1. Background refresh deliberately follows a changed file in List view

`FileListController.setEntries(...preserveState: true)` remembers a selected item
that was visible, restores the old clip origin, then calls `scrollRowToVisible`
if the re-sorted item moved offscreen (lines 705–709). Editing metadata can change
its sort position. The old UI regression `open-metadata-refresh-keeps-selection-visible`
explicitly moves the selected file from row 0 to 39 and expects it still visible.
This test protects auto-follow, not the stationary viewport the owner is requesting.

Separate explicit transfer completion `revealDropped` selects/scrolls the first
landed name in every displayed destination pane, not only the focused one.
Watcher scheduling defers if inline editing is already active, but its delayed
execution and async listing completion do not recheck editing before replacing
rows. An edit started during that gap can still be cancelled by `setEntries`.

Confidence: source-confirmed scrolling/refresh policies and test-contract mismatch;
no live symptom/native viewport reproduction was performed in this session. This
does not establish the cause for every mode, nor prove a folder actually navigated.
Next bounded checks should separate viewport offset, top-visible item, selected
item, sort order and actual directory URL; include edits/moves while scrolled,
rename/drag started after refresh scheduling, and a contrasting explicit Reveal.
Preserve a stable viewport for passive refresh; separate explicit navigation/sort/
Reveal from background mutation, rather than globally disabling refresh.

## 2. Conflict choice already applies to the entire submitted batch

`askConflictResolution` offers Replace, Keep Both, Skip and Cancel. One result is
passed to one `runTransfer` over all submitted URLs; it is not per-item approval.
The label/body does not make that batch scope explicit. Clear batch-labelled
actions or an explicit apply-to-all surface are preferable to a vague Yes to all.
Do not silently turn on a persistent Replace default to suppress safety prompts.

There is a pre-prompt admission gap: `transferInFlight` is set by `runTransfer`,
only after the async confirmation returns. A second operation can pass entry-point
guards while the first prompt is pending. `CursorConfirm.ask` cancels an existing
continuation when replacing a prompt; that is not request deduplication.

Bounded control-flow probe: compile the exact current `resolveThenTransfer`
unchanged with a gated fake confirmation provider and a no-I/O transfer recorder.
Criteria were written first at `/tmp/pathem-live-diagnosis.p3h0iG/CRITERIA.md`.

```
SINGLE asks=1 pending=1 transferInFlight=false
REPEATED secondAdmitted=true asks=2 pending=2 transferInFlight=false
NO_CONFLICT asks=0 runs=1
PRESET asks=0 runs=1
```

Compilation/executable terminate naturally with exit 0. Single/no-conflict/preset
controls PASS; desired one-pending-confirmation admission invariant FAILS.
Both pending continuations were explicitly cancelled; no files were moved.
This proves reentrancy before transfer starts, not native popover duplication or
that this is the particular prompt the owner saw. A repair needs real callback/
popover delivery, Cancel/retry and distinct-request controls, with batch ownership
held through confirmation as well as execution.

## 3. Other move surfaces must not be conflated with conflicts

- List's file-on-file drop branch opens Move Here/Copy Here even when ordinary
  incoming-to-current-folder drops would be a no-op. The local micro-drag guard
  only rejects travel below 12 points; it does not establish intent above that.
- Downloads filing suggestions start in every ordinary browser window, without
  a user preference gate in startup. Each window independently watches Downloads
  and queues arrivals one at a time. This can produce repeated/unsolicited Move
  suggestions; it has no Move All/skip-all batch surface. Source-confirmed design,
  not a reproduction of the owner's prompt. No owner preference was read/changed.
- Trash confirmation is a separate destructive action and must retain its own
  safety/cancellation rules.

An asynchronous selectable question asks which surface matches the observation.
Live native inspection was refused by the computer-use permission layer; no
alternate UI API, screenshot method, permissions grant or active-window mutation
was attempted. Exact prompt identity and live event sequence remain unknown.

No production fixes, full CI, install, owner app restart, clipboard modification,
new debug marker, credential changes or publication occurred. New Mission 53
follow-ups remain pending; existing intermittent tasks are not declared resolved.
