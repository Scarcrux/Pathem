# CursorConfirm lifecycle: the 48/52 transient observation

Trigger: Mission 53 task 29. `PATHEM_TRANSIENT_UI_TEST` intermittently reported 48/52.
The dismiss-resumes-cancel check and all three default-action checks failed, each with
the popover still shown and its continuation still pending. Later runs passed 52/52, and
a readiness change based on `popoverDidShow` measured 47/52 and was withdrawn
(`CONTENT_CONFIGURATION_TESTING.md`).

Hypothesis, from reading the harness, not yet convicted: one upstream failure is being
reported four times. Each reopen cycle waits for `debugPopover?.isShown == true`. A
popover left open by a failed dismiss already satisfies that, so the harness reads the
button from the old popover, clicks it, and resolves the previous task. The new `ask()`
starts afterwards, so its popover stays shown and its continuation stays pending. The
reported detail would then be exactly the recorded one.

Criteria written before the sample:

- C1 Reproduction. With a DEBUG-only injected dismiss failure (`performClose` skipped)
  on the unchanged harness, the run reports the recorded signature: the dismiss check
  plus `popover-default-completes-once-0/1/2` fail, each with `exists=true shown=true
  pending=true`, and 48/52 overall. If the injection produces any other pattern, the
  hypothesis is refuted and no harness change ships.
- C2 Isolation. After the harness change (each step waits for a popover whose identity
  differs from the one before it), the same injection reports exactly one failure: the
  injected dismiss step. All three default-action cycles pass.
- C3 No masking. With no injection, the fixed harness still passes 52/52, and its
  dismiss check keeps its original condition. The harness change must not alter
  production `CursorConfirm`, skip a check, convert a failure to SKIP, or relax a
  timeout.
- C4 Control delivered. The injected run must show the injection took effect (the
  original popover is still shown after the skipped dismiss); otherwise C1 and C2 are
  not evidence.

What would mean the design is broken: the injection producing 52/52 on the old harness
(it never exercised the cascade), or the fixed harness hiding the injected failure.

Not claimable from this work: why the original dismiss intermittently failed. If the
cascade is convicted, the remaining open question is one native event (a
`performClose` during the show animation that did not close), and a future occurrence
will report as one failure with its own detail instead of four.

## Sample 1: C1 refuted (2026-10-12)

The injected dismiss failure on the unchanged harness reported 50/52, not 48/52. The
injection was delivered (C4): the dismiss check failed with `exists=true shown=true
pending=true`. But cycles 1 and 2 passed, and cycle 0 failed differently:
`completed=true result=nil exists=false pending=false`. The harness had clicked
Continue, yet cycle 0's own prompt resolved as Cancel. So the stale-popover cascade
hypothesis as written is refuted, and no harness change based on it ships.

New hypothesis from that evidence, not yet convicted: inside `ask()`, the prior prompt
is cancelled by `resolve(nil)`, which calls `close()` on the old popover. Its
`popoverDidClose` arrives after the new prompt has stored its continuation. The
delegate does not check which popover closed, so it resolves the new prompt as nil
and closes the new popover. In normal use, this would cancel any prompt that starts
before the previous popover finishes closing, for example the next conflict in a
batch copy right after the user answers the first one.

Criteria for the new hypothesis, written before the next sample:

- C5 Instrument. DEBUG-only telemetry records each `popoverDidClose`: whether the
  closing popover is the current one, and whether that call resolved a pending
  continuation. In the injected run, cycle 0's nil must come from a close whose popover
  is not the current one. If it comes from the current popover, or from no close event,
  the hypothesis is refuted.
- C6 Production reproduction. A deterministic check of back-to-back prompts: answer
  prompt 1 with button 0, immediately call `ask()` for prompt 2 with no wait in
  between, then click prompt 2's button 0. On the current code, prompt 2 must resolve
  as nil (the bug). If prompt 2 resolves 0 on current code, the mechanism does not
  reproduce in production use, and no production fix ships.
- C7 Fix. Only if C5 and C6 convict: `popoverDidClose` ignores closes from a popover
  that is no longer the current one. Then C6 resolves 0, the transient harness passes
  52/52 without injection, and a user dismissal of the current popover still resolves
  nil (the existing dismiss check).

Correction to the example above: the conflict prompt is asked once per batch, not once
per conflicting file, so "the next conflict in a batch" does not occur. The real
exposure is any prompt that appears while a previous popover is still closing, for
example answering a delete confirmation and immediately dropping files that conflict,
or pressing Esc on one prompt and quickly triggering another.

## Sample 2: C5 and C6 convicted, C7 fix (2026-10-12)

Telemetry labels: `current`/`stale` is whether the closing popover was the current
one; `+resolved` means that close resolved a pending prompt as Cancel;
`+pending-ignored` means a prompt was pending and the close left it alone.

- C6 convicted on unchanged production code. Back-to-back prompts: prompt 2 resolved
  `nil` before anyone answered it (`second=nil clickedSecond=false`), close log
  `current+resolved,stale+resolved,...`.
- C5 convicted. In the injected run, cycle 0's `nil` came from a `stale+resolved`
  close. The earlier reopen cycles passed only because the harness clicks within
  milliseconds, before the replaced popovers' closes arrive; those closes all landed
  during the back-to-back check's one-second wait.
- C7 fix: `popoverDidClose` resolves only when the closing popover is the current one.
  Back-to-back then passes (`second=0`), with four `stale+pending-ignored` events, each
  one a cancellation the old code would have made. The existing dismiss check (a real
  dismissal of the current popover) still resolves `nil`.

## Sample 3: the original 48/52, reproduced and isolated

With the production fix in place, the injected dismiss failure reproduces the exact
recorded signature: 48/53, with the dismiss check plus all three default-action checks
failing, each `exists=true shown=true pending=true`. That confirms the original
cascade hypothesis. A popover left open by the failed dismiss satisfied each reopen
cycle's `isShown` wait, so the harness clicked the old popover and the new prompt
stayed pending. Before the production fix, a stale close sometimes cancelled that
stray prompt and hid the cascade, which is why Sample 1 showed 50/52 instead. The two
defects interact through timing, which accounts for the earlier inconsistent counts.

Harness fix (C2): each step waits for a popover whose identity differs from the one
before it. The dismiss check keeps its original condition (C3).

Matrix, each run a fresh isolated debug launch:

| Production | Harness | Injection | Result |
|---|---|---|---|
| old | old | dismiss skipped | 50/52 (stale close cancels cycle 0) |
| old | old + back-to-back | none | 52/53 (back-to-back cancelled) |
| fixed | old | dismiss skipped | 48/53 (the recorded signature) |
| fixed | old | none | 53/53, twice |
| fixed | fixed | none | 53/53, four times |
| fixed | fixed | dismiss skipped | 52/53, only the injected dismiss fails |
| old (control) | fixed | none | 52/53, back-to-back still caught |

The last row is the masking control: the harness change does not hide the production
bug.

Verdicts: C1 refuted as first written (Sample 1), then reproduced once the production
bug no longer masked it (Sample 3). C2, C3, C4, C5, C6 and C7 pass.

Still open: why `performClose` on a popover just after `show()` intermittently failed
to close it. That is the upstream event of the original 48/52, and nothing in these
samples reproduced it without injection. It was the first popover shown by that run,
so there was no earlier popover whose stale close could explain it. With the harness
fix, a future occurrence reports as exactly one failure with its own detail.
