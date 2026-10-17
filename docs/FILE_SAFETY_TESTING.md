# File-operation audit follow-through

Trigger: the owner requested continuation after the October 15 audit of source
9cf8704 reproduced six defects. Mission 56 tracks these separately from the
remaining visual and release-path work. No publication or installation is implied.

## Criteria before treatment

The sample must fail the old source for the convicted mechanisms, while passing
unrelated controls. Do not call a mechanism fixed from a green broad suite alone.

1. Batch Replace Undo restores each source's own bytes and the original destination;
   its returned operations remain in forward order for Redo. Two complete cycles
   must pass for both copy and move. If a newer reverse operation fails, do not
   undo an older operation against the same destination's wrong file.
2. Failed Replace Redo restores its displaced destination for both copy and move.
   A rollback failure must explicitly name the stranded recoverable file.
3. Real created-item registration (batch and New File) survives an external
   reoccupation: Redo restores under a new name, then Undo acts only on that name.
4. A real cut-paste started before a newer private clipboard write must not clear
   or modify the newer clipboard. Confirm the actual disk move also completed.
5. Partial/all-skipped and failed cut-paste retain untransferred URLs/dimming;
   another Paste can finish the remainder and clears state only on success.
6. Selective Undo rejects parent/child, reverse parent/child and equal paths;
   independent and same-prefix sibling controls must still succeed.

Engine regression cases use real disposable files and the real Trash behavior.
App cases extend the mandatory sidebar-transfer native-window scenario, which
already requires isolated temporary config and a private pasteboard. Error sheets
are dismissed only on that scenario's own window. The scenario's clipboard is
private and its JSON preference mutations use the temporary config root. This is
not a certification of every AppKit/system-default side effect at startup.
Full CI is a local regression gate, not an
environmental/hardware or whole-release certification.

## Results

Baseline engine: all three new test functions (five parameterized cases) fail,
with 14 assertion/error issues. Native baseline: 60/73, with independent/equal/
prefix-sibling controls passing and 13 expected bad-path checks failing. After
the narrow repair: focused engine 35/35 and native 73/73 pass. Receipts:
`/tmp/pathem-file-safety-{baseline,treatment}-{unit,native}.log`.

Initial native command used `/tmp`, not this host's Foundation temporary root;
the existing isolation guard refused it with exit 64 before any scenario ran.
Corrected to `$TMPDIR`; this was an instrument error, not a production failure.
Private NSURL pasteboard reads emit sandbox-extension warnings but the actual
cut URL receipts and filesystem outcomes are asserted; no owner clipboard is used.

Expanded native checks also cover a newer actual Cut while an older move is in
flight, cancellation before/after the first engine move, retry, and no Redo for
an entirely refused dependent Undo. Cancellation uses the actual engine outcome
and the production completion helper; it does not claim a native Cancel-button
interaction. Expanded verdict: **88/88 PASS**, including real newer-Cut ownership,
engine cancellation before/after the first move and retry, and the production
history's refusal to register Redo for an entirely refused dependent Undo.
The full gate's fresh warning inventory passes (15 known, zero new); 15 XCTest
and 786 Swift Testing tests pass; product E2E is 67 PASS / 1 existing visual-capture
SKIP / 0 FAIL, including the expanded native 88/88. The complete local `make ci`
exits 0, with current-host ARM64 ad-hoc packaged acceptance **14/14 PASS** and
release warnings 12 known / zero new. This is not universal/notarized distribution
or an installation of this change. The skipped cached-browser capture does not certify visual fidelity;
Mission 53 and its unexplained intermittent failures remain open.

Final receipts: `/tmp/pathem-file-safety-ci.log`,
`/tmp/pathem-file-safety-ci-debug-build.log`, and
`/tmp/pathem-file-safety-ci-release-build.log`. No warning-baseline exceptions
were added. The repository's normal pre-commit gate and workbench landing follow
the verification; there is no push, public release, signing-credential change,
owner-app restart, or installation in this unit.

The baseline and treatment unit logs both reproduce an existing never-mutated
`stale` variable warning in LinkOperationsTests.swift. It predates the repair and
is not suppressed or added to the app's warning baseline by this change.

## Intended repair boundaries

- Reverse operations in dependency order, but return successfully undone records
  in forward order so Redo callers do not reverse the batch again. A failed newer
  reverse blocks older operations sharing that destination. Register Redo only
  for operations actually undone, not the original full batch.
- Replace Redo restores its exact displaced Trash item on transfer failure. If
  restoration itself fails, preserve it and report its recovery location; never
  delete a newly occupied destination to force rollback.
- Creation Redo uses the actual restored URLs returned by `untrash`; successful
  members only. New File/Folder should use the same helper as batch creation.
- Capture pasteboard ownership before asynchronous work. Completion may rewrite
  only that still-owned snapshot, excluding only successfully moved source URLs.
  No-success outcomes keep the snapshot intact; later owners are never touched.
- Selective Undo compares normalized, separator-aware ancestor relationships,
  conservatively treating case-only spellings as overlapping. Prefix siblings
  remain disjoint. This is a history-safety guard, not a filesystem identity API.

## Reproduction

Run `make ci` for the complete normal local gate. Focused engine checks:

```sh
xcrun --toolchain XcodeDefault swift test --build-system native --jobs 2 \
  --filter 'FileOperationsTests|FileOpsTransferTests|FileOpsUndoSafetyTests'
```

For the mandatory native scenario alone, first build normally, then launch the
built executable with `PATHEM_SIDEBAR_TRANSFER_UI_TEST=1` and `PATHEM_CONFIG_DIR`
pointing to a new directory **under the host's `$TMPDIR`**. An arbitrary `/tmp`
path may be intentionally refused on macOS. The scenario creates/releases its
own private pasteboard and deletes only its own generated filesystem fixtures.
