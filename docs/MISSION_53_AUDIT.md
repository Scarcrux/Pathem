# Mission 53 audit — 2026-10-17

Audited source: `bde8cea`. Trigger: owner requested another code audit after the
search interaction continuation. Scope: search/replace session ownership, result
path parsing, related pane navigation and transient save/close behavior. This is
not a whole-repository correctness certification. No production fixes are included.

## Findings, ordered by impact

### P1 — Replace All can rewrite a file outside the selected folder

`Sources/PathemEngine/ContentSearch.swift:123` takes the first `:digits:` in
unstructured grep/ripgrep output as a line-number separator. Legal path components
can contain the same sequence. `replaceAll` then trusts the parsed path at line 69
and writes that URL at line 79, without independently validating its scope.

Reproduced through current production `ContentSearch` and the exact current
`RemoteRunner`, compiled unchanged, using the actual installed search tool:

- Create a disposable directory `scope:12:folder` containing `note.txt` with
  `needle INSIDE`, and an outside sibling file `scope` containing `needle OUTSIDE`.
- Search for `needle` only inside `scope:12:folder`. The returned path is the
  outside sibling `scope`, and the parsed line number is 12 rather than 1.
- Replace `needle` with `REPLACED` in that selected folder. The result reports
  one changed file/one replacement; the outside sibling becomes `REPLACED OUTSIDE`
  while the intended file remains `needle INSIDE`.
- Contrasting ordinary-directory control returns the exact path/line, updates
  its intended file and leaves the outside sibling untouched.

Confidence: dynamically reproduced data-safety violation on private fixtures.
Priority: release blocker; do not trust Replace All with arbitrary selected paths.
Remediation should use an unambiguous tool-output contract and independently
validate write ownership, not simply choose the last colon-number boundary: file
contents can contain that boundary too. Validate both available search backends,
numeric-colon/newline paths, scope escapes and ordinary controls before shipping.

### P1 — Failed markup Save does not veto navigation/teardown

`DocumentPreviewView.offerToSaveIfEdited()` returns false when Save fails
(`Sources/Pathem/DocumentPreviewView.swift:455`). The Done path respects that
return at line 607, but `show(_:)` ignores it at line 264 and replaces the document.
`PaneDocumentViewer.prepareToClose()` also discards it at line 612, and
`Sources/Pathem/PaneController.swift:2536` unconditionally removes the viewer.

Consequently, choosing Save and receiving a write failure can still be followed by
replacement/removal of the edited document when navigating or switching views,
losing the in-memory markup that the failure result is meant to preserve.

Confidence: source-confirmed return-value/control-flow defect; no native failed-save
reproduction was run, and no owner document was modified. Before a repair, exercise
the real failed-save path on a disposable PDF, with contrasting successful Save,
Discard and Done controls. Propagate refusal through callers instead of changing
the helper alone; navigation currently continues after `dismissViewer()`.

### P2 — Find in Files accepts responses from superseded UI sessions

`Sources/Pathem/FindInFilesController.swift:40` replaces callbacks and clears rows
when presenting a new folder, but does not invalidate the current generation.
The empty-query branch at line 132 returns before `gen.bump()` at line 138.
The pending task therefore still passes the generation check at line 145.

Reproduced with the current controller compiled unchanged, actual AppKit panel,
search control, table and ObjC action methods. A controlled backend explicitly
receives each request and releases its continuation; no elapsed-time-only verdict:

- Same-session positive control: backend starts, response is delivered and rows
  appear normally.
- Start a request in folder A, present the panel for folder B, observe rows reset,
  then deliver A's response. Old rows populate the panel titled `Find in folder-B`.
  Selecting the row and invoking the real Open action sends A's match to B's new
  callback.
- Start another request, submit an empty query and observe rows reset, then deliver
  that request's response. Rows reappear while the query remains empty.

Confidence: dynamically reproduced lifecycle failures. The harness only shims
localization/window positioning and uses the exact current GenerationBox; it does
not certify physical keyboard dispatch or the full browser integration. Invalidate
session work on presentation, clear and dismissal, capture request callbacks, and
cover replacement completion ownership as part of the subsequent repair.

## Verification and boundaries

Pass/fail criteria were written before execution in the disposable study root
`/tmp/pathem-audit.diFUPr/PREREGISTRATION.md`. Source copies, harnesses, executables
and exact receipts remain beside it in `RESULTS.md`. Both diagnostic compilations
and executables terminated naturally with exit 0. That means the diagnostic ran,
not that the product is correct: ordinary controls PASS; numeric-colon path and
outside-write criteria FAIL; both stale-session criteria FAIL with response
delivery receipts. No full benchmark or research batch was launched.

No source fix, native installation, owner file/configuration/default-app change,
publication, credential access or foreign-process signal occurred. Only disposable
fixture data was rewritten. Full `make ci` was not repeated for this audit-only
documentation unit; the preceding `bde8cea` CI result does not cover these newly
demonstrated failure cases. All fixes and their regressions remain pending.

Mission 53 remains `now`. In addition to these audit follow-ups, remaining work
includes visual baselines/layout/artifacts (1–3), Finder parity (10), transient UI
(11), broad search acceptance (13), environmental/paired-device sign-off (8/26),
and intermittents (36/39/42). Owner asks (4/9/35), release/publication holds and
native-speaker localization review remain unchanged. Green neighboring tests do
not establish that those open items are resolved.
