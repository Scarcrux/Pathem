# Transient surfaces Unit 2, in progress

The accepted contract is docs/TRANSIENT_SURFACES.md. This receipt is not READY.
Unit 1 landed at 7d3d7fc; Unit 2 starts with 861884b (bounded path display) and
d870e40 (opaque failure renders), both private pending final review.

## Criteria before expansion

All 116 A sites and 47 B sites are accounted for individually against the
classified inventory. A uses the actual app-owned construction; no substitute
widgets are counted as coverage. B uses the real shipped localized strings and
audited runtime fixtures. Each B recipe pins its source builder and presentation
span; changed, missing and duplicate recipes must fail the provenance gate.
Sheet B sites get three presentations with cancel, Return mapping and complete
dismissal; runModal B sites get structural checks only, as designed. A uses both
appearances, de/ja, both host sizes and short/255-character filenames where used.
No real destructive target, network, model call, owner preference write or
Keychain action is permitted. Every uncovered site must have its actual reason,
not a coverage claim. Framework ambiguity exclusions remain INFO only and never
exclude geometry or constraint conflicts.

The final gate compares the exact failed cell/check set against reviewed IDs,
failing on any new or stale finding. Native red exits are retained separately.
Predicate controls and all four corruptions must still discriminate, defaults
must match and unique demo roots must be removed. One make ci is allowed only
when the expanded run is end to end. Unit 2 stays private until coordinator ack.

## Full class B fixture expansion

47 source-bound recipes, 36 sheet sites and 11 modal branches. The 10 previously
validated candidates use their existing production-string recipe. The remaining
37 entries have explicit runtime fixtures matching their inventory rationale,
including full paths, eight failure entries, counts, sync/mirror summaries and
six shipped catalogs. Source provenance negative controls reject changed source,
missing/duplicate sites, wrong builders and missing runtime rationale.

First French structural run: native red, with 14 sites / 25 cell-check pairs
failing check 2. These are retained as new findings, not a baseline yet. Several
runtime failure lists and sync/organize previews exceed both hosts; some also
exceed the visible screen. No geometry predicate was changed. Raw receipt:
.build/transient-unit2-fullb-fr.log. Opaque renders remain in that runner's own
retained scratch directory named by its receipt. German sheet behaviour is
currently running and has not yet been graded.

The first German full-B run finished naturally (172.34 s native, exit 1),
with unchanged preferences and removed demo. It exposed an instrument error:
implicit AppKit OK completes with response 0; explicitly added buttons complete
with 1000 onward. The shared sample subtracted 1000 for both, producing -1000
and false cancel/default failures. Pass the expected native response base from
the audited recipe's explicit button list; do not normalize unknown responses
or baseline these checks 5/6. The original run remains
.build/transient-unit2-fullb-de.log. Geometry reds remain real and unchanged.

Corrected German B-only run completes in 141.93 s native, exit 1. All cancel,
default, dismissal and repeat checks pass. Its only failures are check 2:
94 assertions / 48 distinct cell-check pairs, including repeated lifecycle
observations of oversized alerts. Defaults remain unchanged and demo removed.
Run families can be split with --set b to avoid replaying the already validated
core A sample in every B process. This preserves the exact full B cell set.
Evidence: .build/transient-unit2-fullb-response-de.log. A mechanical signature
edit initially failed compilation before any launch; fixed in build2, original
compile log retained. No failure from that build is attributed to the product.

## Full A entrypoint mounting, instrument design

The first 32 adapters invoke real app presentation entrypoints over an owned
selected image and a private configuration root. Callbacks for external actions
are traps; tests only cancel. New windows are measured, then real Cancel/Close
controls dismiss them three times. All geometry checks remain unchanged. The
DEBUG observation hook records the exact NSAlert sent to beginSheetModal and
forwards original AppKit presentation and completion unchanged. It supplies the
actual accessory subtree to check 3 instead of guessing which framework views
are app-owned. A hook failure is an instrument failure. Both appearances, host
sizes, de/ja and short/255-character names where applicable remain required.
Run groups contain eight entrypoints to keep each process bounded; group counts
and per-site coverage will be validated before the final gate.

Return binding proof is separate from destructive execution: intercept each
button's target/action only while delivering the native key equivalent, record
which original button receives it, then restore targets/actions before the real
Cancel. Binding, modifiers, enabled state and presentation are not changed.
A control must prove that Return reaches the configured button without executing
its destructive callback, and real Cancel must still complete afterwards. This
cannot be used to claim confirmation business logic was exercised.

Initial mount dispatch did not receive its treatment: a mechanical insertion did
not match a compact Swift line, so the invocation replayed B instead (same 48
geometry pairs, native exit 1). No A coverage is claimed for that run. Explicit
mount dispatch and receipt refusal of B-only output under a mount request now
prevent that mismatch. Validate one real mount before the full group. Raw:
.build/transient-unit2-mount-g1-de.log. Source rewrite assertions are mandatory
for subsequent mechanical edits.

The private app launch initially aborted before tests: dyld could not find the
Sparkle framework because the new temporary bundle copied only the executable.
The owner saw and submitted that crash report. It matches the unique test bundle
identifier and test PID; the installed /Applications process remained running.
This is an avoidable launcher packaging error, not a product finding. Preserve
native exit -6 and the failed isolation witness. Package non-system framework
dependencies and preflight them before another launch. No native UI coverage is
claimed for that attempt. Evidence: .build/transient-unit2-private-app-m15.log,
Pathem-2026-11-16-061313.ips.

The full-run launcher now uses a unique temporary application bundle identifier,
so AppKit frame/navigation writes belong to the test domain, not either owner
domain. The exact UUID domain is removed after the test process is reaped.
Dependency preflight and six packaging controls prevent missing Sparkle or missing
localization resources from reaching AppKit. Both owner domains are still compared
in memory. A failed post-packaging probe also showed why a normal app.run callback
must be a run-loop timer, not a Dispatch main-queue block: synchronous nested
run-loop waits cannot reenter a currently draining main-queue block. The probe
reported missing presentation and did not scale. Timer-based launch preserves the
normal AppKit lifecycle while allowing existing async sheet work to run.

Timer scheduling alone was insufficient: the control sheet was attached to its
visible host, but not visible, while NSApplication.isRunning was true. This is
an instrument failure, not an app-sheet defect. A running AppKit harness must
also process its application's queued window/sheet events, rather than pumping
CF timers alone. Add a bounded AppKit event drain and updateWindows in settle,
then revalidate the one-surface probe before expanding. The failed timer-only
receipt is retained in .build/transient-unit2-private-app-m15-timer.log.

The blocking-sheet diagnostic identified the actual mechanism: the host had the
German first-run Demo offer in front of the test control. No FDA guide was
observed. A unique empty test domain lacks the owner's already-offered flag.
Supply demoOffered and fdaGuideDismissed in the process argument domain before
AppKit starts, without writing either owner domain. The earlier AppKit-loop
hypotheses are not accepted fixes: restore the established pre-app.run harness
and remove the speculative event-pump change. Keep the genuine borderless
Escape responder path, then probe it. Require zero startup sheets and delivered
argument state before coverage. Evidence: BLOCKING-SHEETS in
.build/transient-unit2-private-app-blocking-sheet.log.

With first-run arguments delivered, AI command bar Escape now dismisses all
three presentations, restores the responder and leaves no window. The only
remaining red is check 1: AppKit's _NSKeyboardFocusClipView extends 3-4 pt
outside its text field. Retain it under the strict framework-geometry contract;
no framework geometry exclusion was added. Save Layout also passes 40/40 native.
Its first wrapper result still failed because defaults read returns exit 0 and
an empty dictionary for an absent private domain on this macOS. Structured
exports confirmed there were no keys. Cleanup now requires empty plist exports
for both the exact UUID AnyHost and CurrentHost domain, with regression controls
for surviving keys, malformed exports and refusal of an owner domain. The old
wrapper failure remains recorded; it was not a preference leak.
