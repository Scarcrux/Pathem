# Transient surfaces Unit 2, in progress

The accepted contract is docs/TRANSIENT_SURFACES.md. This receipt is not READY.
Unit 1 landed at 7d3d7fc; Unit 2 starts with 861884b (bounded path display) and
d870e40 (opaque failure renders), both private pending final review.

## Current rebase checkpoint (2026-11-17)

The private branch is rebased onto main 3c65e5a. Main's theme, Services, search
Outcome API/reporting and markup close guards are preserved. Encrypted-image
input widths and Undo History already landed separately; those source files now
match main exactly. The M25 fixture returns ContentSearch.Outcome() to match the
current search interface. No GUI test has run during this rebase.

Headless verification: 245 Python controls pass, the native debug build passes,
the presentation inventory passes, shell syntax passes and all twelve catalogs
pass localization lint. Normal commit hooks are required before this checkpoint
is committed. None of these results replaces current GUI qualification.

Current inventory: 197 builders, 196 presentation rows, 75 explicitly excluded
DEBUG/harness expressions and 39 implicit menus. A112 = 103 native adapters plus
nine browser-window sites delegated to accepted task 2; B47; C33 and four wrapper
rows. Those are classified/planned counts, not newly executed native coverage.
All classifications and destructive-default intent survived the identity mapping.
Main's Services/theme menus were merged from their reviewed implicit metadata.

Main now ships twelve catalogs, so the old six-catalog plan is incomplete for
current main. Catalog discovery and B planning include all twelve; A variants
remain German/Japanese. The future full plan is 48 jobs/15,355 possible product
cell/check pairs. That plan was not run. Historical six-locale and 42-job receipts
below apply only to their old source/artifact, never the rebased tree.

Focused CLI commands now require --full, explicit --set and --language, and a
nonempty surface ID belonging to the selected family/group. Lifecycle commands
require an explicit close/quit mode in German. Missing or ignored selectors fail
before native admission; subprocess canaries prove that no app is launched on
those refusals. No automatic all-language fanout follows a focused request.

Unit 2 remains NOT READY: no complete current-source GUI results or reviewed
known-findings baseline exists, and no final CI, land, install or deployment is
claimed. Existing product findings remain open. Source review also notes that
PATHEM_THEME_SHOTS alone is not recognized by isAutomationLaunch; that separate
main hook was not launched or modified here. Earlier sections retain chronological
negative results and historical statuses, not current readiness claims.

## Criteria before expansion

All 112 A sites and 47 B sites are accounted for individually against the
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

## Modal and sensitive-surface factory extraction

Eighteen pure factories are extracted from thirteen production files. Production
still calls the same runModal/beginSheet path with the same buttons, fields,
response indices and post-confirmation guards. Tests can supply a fixture instead
of reading the clipboard, querying Keychain, connecting a daemon, or executing an
operation. Every factory and production caller (including its Cancel guard) has
a reviewed source fingerprint; mutation controls reject changed construction,
removed Cancel guards, wrong adapters, missing profiles and unclassified sites.
The constructor/presentation identity map retains all 196 census sites. All B
content fingerprints are unchanged except one manually reviewed whitespace-only
host-key formatting change. Initial build of production extractions passed.
The new original-style modal runner is still awaiting its sample, not qualified.

A source audit found a startup isolation gap: BrowserViewController.viewDidLoad
unconditionally starts SharedDiscovery and DeviceWatcher. Their start methods
invoke Bonjour browsing and USB/adb discovery even under the transient flag.
Earlier receipts prove test actions did not invoke transfers, but cannot support
a claim that startup discovery was isolated. Do not launch more native samples
until the transient family suppresses these two providers before their I/O calls.
Use DEBUG counters to prove the real start attempts took the skip path; an
actual-start count is never an accepted known finding. Other automation and
interactive launches retain their existing behavior.

## Checkpoint 2026-11-16

This is a resumable private checkpoint, not Unit 2 READY. The 21 pure-factory
profiles and 62 real-entrypoint adapters are implemented and source-bound. Native
coverage remains partial: corrected B German behaviour, initial custom groups 1
and 2, and isolated Save Layout, AI bar, Crop and template-modal pilots. The last
expanded 62-adapter tree still needs its compiling hook and native qualification.

The crop sheet has a confirmed check-2 finding: 720x600 against a 720x420 host in
all three presentations, for short and 255-character filenames. Cancel, Return
observation, responder restoration and no accumulation pass. Receipt and render:
.build/transient-unit2-crop-probe.log; retained owned scratch is named by that
receipt. This remains red. The template editor has an app-owned ambiguous stack
and an unbounded hint clipped horizontally in German. Its geometry reds remain,
but its modal Return proof is not yet qualified: waiting for default-button
assignment alone did not fix dispatch. The established sheet control also calls
makeKeyAndOrderFront; the next modal probe tests that exact missing step. The
queued probe was cancelled before admission to make this checkpoint; no native
result is claimed for it. Earlier failed probes are retained.

Strict factory receipt controls reject missing cells, missing cycles, omitted
suggestion-state measurements, duplicate site claims, failed setup, missing
startup controls and modal timeouts. Together with packaging, inventory and
provenance controls, 65 focused Python checks passed before checkpoint formatting.

The coordinator applied the owner's explicit-confirmation rule to Find in Files
Replace All, Process Viewer Quit/Force Quit and Reset Data, and to the same kind
of explicitly invoked confirmation elsewhere. The inventory records the exact
2026-11-15 quote and its application by pathem-claude on 2026-11-16, owner informed.
No production default changed. Unsaved markup's Save/Discard prompt has no Cancel
in source; its native confirmation, Escape behavior and trigger audit are pending,
and no production repair has been authorized.

Startup discovery is also unconditional for layout-matrix and site-shot launches:
viewDidLoad calls both providers and neither provider previously checked an
automation flag. Current guards intentionally cover transient tests only. This
checkpoint does not claim those other launch families have isolated discovery.

Untouched final work: remaining A sites, complete native variant runs and
per-inventory coverage report, default-intent enforcement, known-findings
comparison gate, four corruption runs on the final artifact, E2E native wiring
and one authorized make ci. No baseline is accepted, no CI has run, and Unit 2
remains private until review.

## Post-checkpoint controls and native pilots

The requested clean checkpoint is 3e49535. Its normal formatter, full Swift tests,
source-guide and localization hooks passed. No Unit 2 land followed.

The missing modal step is convicted: makeKeyAndOrderFront before observing Return
removes every template check-6 failure; the same native pilot retains only checks
1/3. Source/artifact-bound receipt: .build/transient-unit2-modal-key-probe.log.

The torrent save panel passes 106/106, native and wrapper exit 0, including its
real app-owned filename-suggestion accessory after success/failure changes, Return
observation, Cancel, responder restoration and three presentations for short and
255-character names. Its native framework subtree is INFO for ambiguity only;
all geometry remains measured. A positive/negative ownership control proves an
under-constrained supplied accessory still fails. Both owner domains unchanged,
private UUID domain cleared and unique demo root removed. Receipt:
.build/transient-unit2-filepicker-probe.log.

TS-U2-F03: unsaved markup has no Cancel. The original-style modal factory is red
only on check 5 in all six short/long pilot presentations. Save receives Return,
there is no third button, and Escape has no key-equivalent binding. The runner
records that fact then aborts only its own modal fixture; abort is not counted as
Cancel. A direct native Escape-event probe is still pending, so no claim is made
about a physical Escape key beyond the missing binding. Source audit routes this
prompt through viewer Done, folder navigation, view-mode changes and opening a
different document. No call from applicationShouldTerminate or WindowManager's
window-close path was found; quit/window-close protection remains unverified,
not claimed covered. No production change is authorized. Raw receipt:
.build/transient-unit2-markup-no-cancel-probe.log; render is in that receipt's
retained owned scratch.

## Markup lifecycle pilot criteria, before running

The owner's follow-up asks whether real window close and Quit lose unsaved edits.
Each runs in a unique private fixture app, with its actual delegate and window
manager. An owned blank PDF gets a real unsaved highlight; the setup must prove
edited=true while its on-disk annotation count remains zero. A positive control
uses the same real PDF writer to save an annotation and change owned bytes.

Close must invoke performClose on an owned secondary browser and prove that the
window manager removed it. Quit must run the actual NSApplication event loop and
call terminate with the real delegate; the parent must observe natural exit 0
and the native will-terminate witness. A timer only observes/aborts an unexpected
guard on this owned fixture, never chooses Save or Discard. Prompt observation,
PDF annotations and disk bytes decide the result. Original bytes and zero saved
annotations after unguarded close/quit mean TS-U2-F04, not PASS. A prompt or saved
annotations can disprove the hypothesis. Missing treatment, failed save control,
unknown termination, signals, timeout or changed post-reap evidence break the
instrument and are never baseline findings. The fixture survives demo cleanup
under the launcher's own receipt directory so the parent hashes it after reaping.

## TS-U2-F04: real Quit and window close lose unsaved markup

Both preregistered lifecycle pilots confirm this finding on owned PDFs. The
real writer control passes (changed owned bytes, saved annotation count >0).
The treatment has a real unsaved highlight and edited=true, with zero saved
annotations before the operation. Real secondary-browser performClose removes
that browser from WindowManager without a prompt. Real NSApplication.terminate
from its running event loop reaches PathemAppDelegate and the will-terminate
notification, then exits naturally with code 0, again without a prompt.

After reaping each process, the parent independently hashes the surviving owned
PDF. Both remain byte-identical to their originals, with zero saved annotations.
Close native is red 17/18 with L-close check5; Quit's native exit 0 is the actual
application terminating, not a test pass: its parent disk-evidence verdict is red
on L-quit check5. Both owner defaults domains are unchanged, private UUID domains
are cleared and demo roots are removed. No timeout, signal, mocked delegate or
destructive production action supplies this evidence. The source-convicted
missing guard is now a measured behavior; no production repair is authorized.

Receipts: .build/transient-unit2-markup-close.log and
.build/transient-unit2-markup-quit.log. Before-close/quit renders:
.build/TS-U2-F04-close-before.png and .build/TS-U2-F04-quit-before.png.

The direct native Escape-event probe for TS-U2-F03 also leaves the Save/Discard
modal visible in all six presentations. Escape has no key equivalent, reaches
no button and does not dismiss via the normal window event path. The fixture
runner then aborts its own modal, which is never counted as successful Cancel.
Receipt: .build/transient-unit2-markup-escape-event.log and the matching raw
TSAMPLE NO-CANCEL-EVENT rows.

## Ownership and remaining isolation items

Pathem-claude owns the markup production files from 3e49535 until its owner-ruled
F03/F04 repair lands. This lane does not change PDFMarkupView, DocumentPreviewView,
MarkupController or PaneController markup paths. Lifecycle probes are separate
DEBUG files and are retained as regression checks.

Four conservative A context-menu rows are now resolved as standard class C by
reviewer ruling. The table retains all four physical expressions and records
implicit attachment locations in list, columns, icons and gallery. A new source
gate detects a provider's custom view assignment, reports effective class A and
fails until classification and structural coverage are reviewed. Eight controls
cover positive native menus, multiline/optional custom assignments, comments,
strings, missing providers, stale attachments and unreviewed C downgrades. The
current class totals become A=112, B=47, C=33, plus four unclassed wrapper rows;
the original requested A denominator was 116 before those four were resolved.

Open isolation item: WindowManager's secondary browser under automation still
uses a live sidebar, including cloud/provider labels, rather than the demo
sidebar. The lifecycle renders therefore stay private and must never be
committed or published. The owned edited PDF and post-reap disk proof are not
owner documents. Reviewer accepted recording this as an open harness item.
The source audit also found layout-matrix/site-shot discovery starts, as above.

## Remaining editor construction

Five more pure factories now cover the Shortcut selector, archive save-back,
sidebar symbol input, color-rule editor and full connection editor. Production
presentation and confirmation guards stay in their original callers. Instance
factories retain their real controller so protocol/field change targets remain
valid; provenance checks reject substituting another controller type. Profiles
now total 31 for 25 A sites, including new/SFTP/FTP/S3/Azure connection forms
and the existing Commander-key factory. The class B source fragments remain
byte-identical after rebinding their moved locations.

Initial color-rule and connection editor probes retain geometry/ambiguity reds.
Their Return reds are not findings yet: the sheet branch lacked the same
makeKeyAndOrderFront preparation already convicted in the modal branch. Apply
that instrument step, then repeat the two samples before expanding. Receipt:
.build/transient-unit2-color-editor-probe.log and
.build/transient-unit2-connection-editor-probe.log.

The incremental build also exposed two new DEBUG lifecycle capture warnings:
its local persist function had no Sendable type while timers capture it. Give
that actor-isolated closure an explicit @Sendable type; do not waive new warnings
in the baseline. The original warning-bearing build is retained at
.build/transient-unit2-editor-factories-build.log.

The corrected editor pilots remove all check-6 failures. Color rule is red only
on checks 1/3 (58/70); Connection is red only on checks 1/2/3 (52/70), with its
486pt sheet against the 420pt host. Both cover short/255 strings and three
presentations, with unchanged defaults, cleared private domains and removed demo
roots. TS-U2-F05 records color form geometry/ambiguity; TS-U2-F06 records connection
form geometry/ambiguity/oversize. No product fix is inferred for the framework
empty-label geometry that appears alongside those app-owned ambiguities.
Receipts: .build/transient-unit2-color-editor-key.log and
.build/transient-unit2-connection-editor-key.log. Renders:
.build/TS-U2-F05-color-editor.png and .build/TS-U2-F06-connection-editor.png.

The explicit Sendable closure initially failed compilation because its catch
needed explicit self.emit. That instrument-only compiler failure launched no
native process. The corrected incremental build has no new source warnings;
only SwiftPM's existing build-system deprecation remains. Both failed/corrected
logs are retained (.build/transient-unit2-editor-key-build.log, build2.log).

Exact full-B receipt validation now checks every expected cell, per-cycle check
counts, builder identity, site coverage and setup success. Eight controls reject
unknown replacements, missing cycles, duplicated claims, wrong builders and
missing inventory control. Known-findings comparison has eleven controls for
new/stale pairs, missing runs, changed source, unsafe setup/timeout/constraint
errors, malformed pairs and the separate Quit parent verdict. No baseline is
created or accepted yet; these validators do not make native reds green.

## Reset isolation and guard counterexample checkpoint

The Reset UI now comes from the exact factory the production caller uses. The
mount never constructs the callback that deletes Keychain entries or changes
the folder handler. Before this change the Reset adapter was draft only and
had never run. Both owned UI probes pass: mount 47/47 and factory 44/44, with
unchanged owner preferences and complete cleanup. The existing FileOpening
interception is enabled and positively controlled for every transient run;
unexpected opens or system-default requests fail the external-boundary check.

The close probe now recognizes a real Cancel guard that preserves its window
and edited state, instead of treating a refused close as an instrument failure.
Its synthetic guard control was red before correction and green after. Guard
prompts receive actual Cancel once per window, or a fixture-only abort if no
Cancel exists. Original close and Quit data-loss cases remain red on check 5
with post-reap bytes unchanged and zero annotations. Receipts:
.build/transient-unit2-markup-close-guarded-instrument.log and
.build/transient-unit2-markup-quit-guarded-instrument.log. No production markup
file changed. The warning gate on the Reset build reports 3 known, 0 new.

## Confirmation adapter expansion

Adapters m63-m67 add local permanent deletion on an owned file, fixture-only
Empty Trash/remote deletion/recoverable Trash prompts through the real shared
CursorConfirm construction, and the actual registered Transfers command. The
three fixture-only caller recipes pin the complete production caller source;
missing provenance or changed caller code is refused. They do not enumerate the
real Trash or create any remote provider. Owner-approved Return confirmation
intent is checked for all four Trash prompts.

The Empty Trash pilot passes native and wrapper 46/46, with actual Return
observation, Cancel, restored responder, three presentations and no accumulation.
Preferences unchanged, private domain cleared and demo root removed. Receipt:
.build/transient-unit2-empty-trash-ui-probe.log. The registry is now 67 mounts
and 32 factory profiles (one overlapping Reset site); these are adapters, not
a claim that every variant has run. Remaining new A adapters are Rule Editor,
Photos, Torrents window, FDA guide, Reclaim panel, repository Reclaim and Trim.
The latter need their owned-data/provider boundaries before native launch.

## Exact-receipt validation exposed two instrument defects

The first strict German B run completed naturally: 2017/2128, native red. The
new validator refused its b08 structural count and site-coverage receipts. Raw
evidence shows a truncated/interleaved record, not a duplicated product surface:
`COVERED ... site=Sources/TSAMPLE: PASS cell=B-b08...`. Buffered Swift print and
unbuffered FileHandle writes shared stdout. Every transient receipt now uses
one unbuffered trace writer; a regression control rejects reintroducing print.

The other eight non-geometry pairs were correlated b03 instrument failures.
The real Cancel-first extension alert has no native default. The runner wrongly
required index 0 and waited for an inert Return to dismiss it, manufacturing
Cancel/dismiss/accumulation failures. No production default changed: the runner
now verifies Return is unhandled and leaves the alert intact when no default
exists, then presses the real Cancel. The focused two-host, three-cycle sample
passes 72/72, including exact subset receipts and complete preference cleanup.

Receipt: .build/transient-unit2-extension-default-probe.log. The original failed
full run stays at .build/transient-unit2-fullb-strict-de.log. A compile-only
implicit-self error while introducing the trace method was corrected before
any further launch; both build logs are retained. The complete family rerun is
pending and has not been called PASS or accepted as a baseline.

The strict German B rerun completes with exact receipts accepted: 2029/2128
native checks, 127.44 seconds, 49 distinct failing cell/check pairs, all check 2
(oversize stress-string alerts). There are no setup, missing-cycle, default,
dismissal or receipt errors. Both owner defaults domains are unchanged; the
private domain and demo root are removed. This is a native red, not a gate PASS.
Receipt: .build/transient-unit2-fullb-strict-stream-de.log and the matching
transient-sample-clean-de-full-b-g0.json. All 108 Python controls pass. No
known-findings baseline has been written yet and the other languages remain
pending. The source-stream and no-default fixes are harness-only.

## Remaining owned-provider adapters

M68-M74 now supply Rule Editor, the real Photos denied UI, fixture-backed
Torrents list, FDA guide, Reclaim panel under an owned home, real repository
Reclaim and AVKit Trim. The process viewer also receives fixture process rows.
DEBUG boundaries avoid PhotoKit authorization/library access, daemon startup,
TCC reads, live-home cache enumeration and live process names. Trim receives a
fresh generated four-second silent AAC file and must report real AVKit trim
readiness; repository Reclaim creates a Git repository under its owned fixture
with templates/config disabled. Cancel never runs real destructive callbacks.
These are written adapters, not yet a full-variant coverage claim.

The first provider build used the shell's older Swift instead of the project's
Xcode-paired toolchain and failed during dependency manifest compilation before
any native launch. The log explicitly names Swift 6.1.2 and incompatible SDK
headers. Preserve .build/transient-unit2-provider-build.log; the corrected
attempt uses make build with native SwiftPM and two jobs, as the repository
requires. No product failure or successful probe is inferred from that attempt.

The corrected Xcode/native build passes. M68 Rule Editor completes all three
presentations for both names; check 3 exposes app-owned ambiguous stacks and
check 2 its 440pt sheet against the 420pt host (65/77). M69 Photos denied-state
first presentation cancels cleanly, but the cached window does not reappear on
the second invocation. The strict receipt validator correctly refuses incomplete
three-cycle coverage. This is not baseline-eligible evidence yet. Photos caches
a normally released-on-close NSWindow without setting isReleasedWhenClosed=false;
a narrow lifetime repair needs its own commit and an identical red/green probe.
No Photos library access is performed. Receipts:
.build/transient-unit2-provider-m68.log and transient-unit2-provider-m69.log.
Remaining provider samples stopped before expansion on the M69 incomplete run.

The other five provider pilots finish without missing treatment or isolation
errors. M70 Torrents: 65/71, check 1 row geometry; M71 FDA: 41/44, check 3
app-owned stacks; M72 Reclaim: 59/71, checks 1/3; M73 repository Reclaim: 71/71;
M74 Trim: 71/77, check 1 AVKit geometry. Every presentation, Return interception,
Cancel, responder restoration and three-cycle accumulation check passes.
AVKit canBeginTrimming is positively observed on all six short/long cycles.
All owner defaults are unchanged, private domains cleared and demo roots removed.
Framework geometry reds (including AVTrimIndicatorView) remain red and are
reported as geometry observations, not an inferred product mechanism. Receipts:
.build/transient-unit2-provider-m70.log through m74.log. No full variants yet.

## Photos cached-window lifetime repair (separate production unit)

Red first: .build/transient-unit2-provider-m69.log and its retained private raw
native log show the first Cancel succeeds, then check 4 fails on the second
invocation and coverage is incomplete. PhotosBrowserController owns a cached
NSWindow but left AppKit's release-on-close behaviour enabled. Setting
isReleasedWhenClosed=false keeps that exact window valid for re-presentation,
matching the other reusable controllers. The identical corrected pilot now
completes all three presentations, Return observation, Cancel, responder and
no-accumulation checks. It is native 41/44 only because the existing check-1
empty label geometry remains red. Exact receipts accept the complete run;
owner defaults unchanged, private domain cleared, demo removed. Receipt:
.build/transient-unit2-photo-lifetime-probe.log. This proves the reopen repair
for the denied-access fixture, not populated Photos authorization or export.

## Content-change and Cancel metadata control, before full expansion

Twelve asynchronous mounts now require delivered post-load content and repeat
checks 1-3 on that frame, as well as first display. Fixtures include real text
differences, a duplicate pair and a Finder comment so a loading placeholder
cannot masquerade as completion. Exact receipts require all three post-load
observations. Cancel snapshots now include empty directories, file modes,
xattrs and symlink identities, as well as bytes, without reading link targets.

Its first native negative control failed before any mount. Diagnostic evidence
isolates the symlink stage: eight unchanged snapshot entries after a deliberately
dangling link was successfully created. Foundation DirectoryEnumerator omitted
that entry. Explicit name enumeration followed by attributes/lstat retains links
without following them. This is a harness defect, not a product finding. Original
receipts: .build/transient-unit2-readiness-m36.log and
.build/transient-unit2-metadata-diagnostic.log; raw diagnostic line is in the
matching transient-sample log. Revalidation is pending, not called PASS yet.

The full plan accounts for 103 native A sites, 9 task-2 delegated browser sites,
and 47 B sites, across 42 launches. The input digest now includes engine/vendor
source, all shipped/built resources and linked framework content, with negative
controls for changed non-catalog resources and dependencies. The full comparison
runner is written but has not run or accepted a baseline. 123 Python controls
pass before native revalidation; no CI or Unit 2 land.

The corrected metadata counterexample passes in all five changed-content
samples: Diff, Duplicates, Metadata, Inspector and Trim. Their exact initial and
post-load receipts are complete; only geometry/ambiguity reds remain. The next
core pilot stopped before presentation because the older core fixture guard
still expected the former bytes-only snapshot shape. That is our representation
regression, not a product failure. Update its setup check and its intentional
Rename/Delete expected transitions to the richer snapshot, preserving root
metadata and each moved file's metadata; then rerun the core and all four
injections. The failed core receipt stays in
.build/transient-unit2-core-private-pilot.log. No full plan has run.

## Validated composition and owner-desktop hold

The corrected private core pilot passes natively with zero failures. Each of
the four injections is delivered and turns its named check red, and each
validation wrapper passes. Receipt:
.build/transient-unit2-core-snapshot-pilots.log. The three-family composition
sample then completes all three jobs naturally: full owned repository Reclaim,
full Reset factory and the two-host b03 plain alert. Every native exit is zero,
no failure pairs, all isolation checks pass; the exact empty-baseline comparison
passes in 42.30 seconds. This is a three-job sample, not full coverage. Receipt:
.build/transient-unit2-orchestrator-sample.log; immutable plan, native receipts
and summary under .build/transient-orchestrator-sample-v1.

Seven independent runner controls cover complete success, exact known native
red without rewriting it, new/stale failures, source/preferences changes and
stopping after an instrument error. The first staged control fixture omitted
its required seconds field and failed; correcting that fixture yields 7/7.
Both staged logs remain; no product failure is inferred from the test fixture.

On 2026-11-16 the owner objected to the repeated visible screen tests. The lane
has no active or queued native GUI phase and will not launch further visible
tests until a less disruptive window is coordinated. Source work and headless
checks can continue. The full 42-job run, remaining full variants, final finding
baseline, native E2E wiring and make ci are pending. Do not mark Unit 2 READY.
Future execution should use focused headless development and one coordinated
visible batch, rather than repeated desktop interruptions.

## Desktop-friendly planning and headless hardening

Plan-only mode does not launch AppKit or create run artifacts:
`python3 test/transient_surfaces_full.py --plan`.
For a targeted development preview, add `--surface m39` (repeatable). An A
selection preserves de/ja, sizes, appearances and filename variants but reduces
the launch set to the selected surfaces. B keeps all six catalogs. Focused
runs can only record observations; they cannot qualify the full known-findings
baseline. The full 42-job release plan remains unchanged. Further visible runs
remain on hold; these commands are preview examples, not authorization to run.

A headless replay counterexample proved the new orchestrator could reuse an
old matching receipt if its launch adapter returned without writing a new one.
The control was red (True is not false); fresh per-invocation identities now
bind each collected receipt to the current call. Old logs are preserved rather
than deleted. A missing framework binary inside an existing framework directory
is also rejected during input enumeration. These Python-only corrections do
not claim fresh native GUI qualification. Receipts:
.build/transient-unit2-stale-receipt-red-control.log and
.build/transient-unit2-focused-freshness-controls.log. An earlier dotted unittest
invocation failed in discovery before that control; the explicit fixture call
retains the actual failing assertion independently of traceback formatting.

## Parallel review and main integration

Owner requested maximum parallel agents. Three independent reviewers examined
core/gate exactness, coverage/default/tooltip checks and main's markup repair.
The headless checkpoint was committed as 8c5d739, then rebased onto main df6d315
(rebased checkpoint 4d3d507). Roadmap conflicts preserve the owner's release
choices and completed F03/F04 finding; the markup code keeps main's three-way
LeaveChoice. The obsolete private two-button factory is removed. F04 now uses
saveMarkupAlert(fileName:) from the real askToSave caller, Cancel index 1.
All affected production sites and factory hashes are conservatively rebound.

Review convicted three potential false accepts using headless counterexamples:
core receipts could substitute wrong variant/cycle records, repeated predicate1
could replace missing predicates, and the input digest omitted the defaults
comparison helper. Exact cells, cycles, geometry phases, core site claims,
predicate identities and helper hashing now close those gaps. An independent
reviewer confirmed 12 exact-core/predicate controls and the Japanese transcript.
CORE-SITE records shared UI construction, not whole business-entrypoint execution.

The tooltip and presentation checks now test app-supplied icon-only controls,
sheet/window/popover placement, anchor/host identity and exactly one additional
visible window. Factory check5 also snapshots private configuration before
construction and after dismissal. It still does not prove every in-memory
pane/tab/session value unchanged. Factory duplicate Return bindings fail check6.
A proposed blanket inert-Return allowance was rejected: a default might not yet
be installed. Preserve current default-ready behavior unless an individual
no-default recipe is independently convicted and reviewed.

The new E2E scenario invokes the complete exact known-findings comparison, with
no placeholder baseline. Missing, malformed and schema-valid impossible baseline
cells/checks are rejected before any app launch. The baseline bytes/SHA are frozen
for the run. The complete plan has 13,663 possible product cell/check pairs.
The initial patch application against pre-deadline context failed; the reviewer
regenerated it against the current tree, with 26 copied-tree controls passing.
The integration currently passes 186 Python tests and bash syntax checks. The
Xcode/native debug build passes in 20.97 seconds, with no GUI launch. Existing
private native samples predate these changes and are not final qualification.

Internal admission budget is 2250 seconds with 60 seconds reserved for cleanup;
per-native waits remain at most 180 seconds and are recalculated after packaging.
The 2400-second E2E outer alarm is not by itself proof of descendant cleanup.
An owned-child cancellation supervisor is being reviewed before final checkpoint.
No further visible test has run since the owner-desktop hold. Full variants,
a real baseline, final injections, close/Quit reprobes and one authorized CI run
remain pending the coordinated visible test window. Unit 2 is not READY.

## Final headless integration checkpoint

Parallel review also caught two composition hazards: an empty plan could yield a
zero-launch match, and a schema-valid baseline could name impossible cells and
waste the visible batch before failing stale. Plans now require nonempty,
canonical, unique jobs, and baseline pairs must belong to that exact plan before
output creation or process admission. These have independent negative controls.
The final integrated suite passes 201 headless checks; shell syntax and inventory
gates pass. Core and factory check4 now share the mount suite's exactly-one-new-
window assertion, closing the case of a second window disappearing on dismissal.

The owned-native supervisor creates a private child session, preserves the raw
native status and retires only that captured child/session on timeout or ordinary
TERM/INT/HUP/ALRM interruption, with bounded TERM/KILL/reap. Driver cleanup then
checks the unique domain, owner defaults and demo root. The E2E alarm targets the
Python runner directly; its awake assertion is scoped after preflight. Seven
harmless Python-process controls passed; no AppKit or real caffeinate was launched
by those controls. Parent SIGKILL and unverified leftover pipe holders remain
explicitly unattested, never a quiet/PASS claim. A failed initial universe-patch
context check was retained; the regenerated post-deadline patch passed review.

No final visual qualification is claimed. The previous native sample receipts
were collected before this rebase and reviewer changes. A real checked-in
known-findings baseline has deliberately not been fabricated. The coordinated
visible batch, fresh injection/markup probes and final CI remain necessary before
READY. Owner-desktop timing choice is still pending; visible tests remain paused.

## Final native control caught a site-lookup instrument defect

The first post-review native clean pilot stopped before expansion. Swift's new
core Rename lookup counted both class A Rename and class B extension confirmation
in the same file; the Python validator correctly filters A. The guard failed
after presenting Rename, leaving its sheet attached and causing subsequent
Reclaim presentation/conflict dismissal failures. No product finding is claimed
from that cascade. Filter the Swift lookup to A and validate sites before any
presentation, then repeat the control. Original raw/JSON evidence is preserved
under .build/transient-final-controls; no later control or full run launched.

## Painted-bound geometry correction

The M42 diagnostic disproves deferred layout: before/after painting both report
13 issues, while a representative field's real frame is (2,3,60,14) within a
64x20 cell. Its visibleRect is (-8,-3,635,20), extending beyond its own bounds.
The scrolling branch incorrectly treated that exposed region as painted extent.
Measure visibleRect intersected with bounds before conversion, use the same
rule for overlaps, and retain the original alignment rectangle outside scrolling
content. Meaningful collapsed controls/containers still fail; ordinary offscreen
scroll children do not. Exact nondrawing leaf spacers and empty readonly,
unbordered/nonselectable labels do not become fake clipped UI. Predicate controls
exercise all of those distinctions; real displaced viewport and label overflow
checks remain red. Native validation pending. M42 diagnostic and full-v1 renders
are retained, never baselined as product spill.

## Resumed window: final instrument sample v9

All 13 sample launches completed on source/artifact digest
744bc5ca8532a05bd8e51db7c7474d2a08ba17d01580c3bc2d643af6bd16c746.
Clean core, M02, M42, M23, markup confirmation and actual close/Quit probes have
native exit 0. All four injected corruptions retain exit 1 and discriminate on
their intended checks. M07 retains four size/ambiguity pairs; archive saveback
F23 retains six dependent Cancel/dismissal/accumulation pairs. Those are sample
observations, not a final known-findings baseline. The independent audit reparsed
all raw logs, exact repeat phases, native byte hashes and retained PNGs. All
preference/domain/demo isolation witnesses passed. Headless suite: 229/229 PASS.

M02's remaining geometry reports were the empty framework informative label and
its sole NSTextFieldSimpleLabel helper. A/A/hide/restore pixel comparisons matched
with unchanged frames and first responder in all six catalogs. The final German
short/255-character probes also detected the separate visible-ink control.
The geometry exception uses only the two identities from that actual alert, with
empty readonly text, no placeholders, no active editor or accessory ownership,
exact helper shape and no decorations. AppKit's measured backing-layer cache is
allowed only as NSViewBackingLayer/NSViewBackingLayerContents and the exact helper
layer. Text, placeholders, unknown children and collapsed app input still fail.
The native predicate proves each distinction. No framework class is waived globally.

Negative results remain private: the initial inset control placed its negative
case fully outside the viewport, so it was correctly invisible; the corrected
partially visible case discriminates. The initial blank-label guard incorrectly
assumed no backing contents after drawing; diagnostics convicted the native cache
wrapper and the pixel experiment separated cached contents from visible ink. A
new owned-input predicate initially passed an unrelated alert; that masked failure
was corrected before v9 by measuring the owned root without that alert. Earlier
v6/v8 refusals are instrument failures, never product findings or baseline input.

The receipt gate now demands exact per-check cycles and geometry phases for
mounts, factories and class B sheets. Count-preserving duplicate-cycle controls
fail. Current failure PNGs are decoded, fingerprinted and launch-bound; missing,
corrupt or changed images are instrument errors. Historical baseline paths are
never used as current capture evidence. The completed v9 is eligible to validate
the design for full expansion; the previous interrupted full v2 is not.

No final full qualification, baseline, CI, land or install is claimed here.
Evidence: .build/transient-final-controls-v9 and .build/transient-headless-v9.log.

## Targeted product fix: encrypted disk image inputs

Owner direction changed validation to targeted regressions and stopped broad GUI
replays. The confirmed M12 defect was actual zero-width Name/Password fields in
the encrypted disk image sheet. NSStackView uses Auto Layout; each control's
initial 240 pt frame did not provide a width constraint. Give both controls their
intended 240 pt width through the existing row builder. Production change: one
constraint; presentation/callback behavior is unchanged. Rebind only shifted
inventory/mount source locations.

The existing red M12 geometry regression is the regression test. Only that dialog
was launched, using German at a 720x420 host, short and 255-character filenames,
three cancel/reopen cycles each. Before: both editable inputs had zero width and
check 1 failed. After the one-line fix: all six check-1 observations pass, as do
size, ownership, cancel, Return mapping, dismissal and repeat observations (six
passes each). The retained before/after renders confirm usable fields. All owner
preference/domain/demo/catalog witnesses pass; no disk image is created.

The whole targeted profile remains native exit 1, 70/76, because six check-3
observations report a separate ambiguous stack. Do not report that profile as
PASS. A follow-up experiment constraining the accessory to its initial 340 pt
width left the warning and increased the ambiguous-node count, so it was removed.
The final change is exactly the already-measured input-width constraint; there
was no visual replay after removing the failed experiment. Stack ambiguity remains
an open follow-up, and Unit 2 full qualification remains incomplete.

Private receipts: .build/dmg-input-width-only-negative.json,
.build/dmg-input-width-only-native.log and the dmg-input-fixed diagnostic PNGs.
Refuted accessory-width experiment: .build/dmg-accessory-width-regression.log.
No full matrix or GUI CI replay ran for this fix. No installation or land.

## Targeted product fix: Undo History layout

M30's retained pre-fix render shows the explanatory hint overlapping the buttons
and a zero-height bottom toolbar. The hint was constrained with Auto Layout but
still translated its autoresizing mask. Disable that translation on the hint;
its existing top/leading/trailing constraints then determine its layout without
conflicting frame-derived constraints. Other source changes are swift-format only.

After Claude explicitly handed over the GUI window, run only:

```sh
python3 test/transient_surfaces_sample.py clean --full --set mounts --only m30 --probe-one --language de
```

Result: native exit 0, wrapper exit 0, 49/49 checks, 4.01 seconds total. One app
process, German at the minimum 720x420 host, three close/reopen cycles over an
owned empty ActionHistory. Geometry, text fit, ambiguity, presentation, cancel,
Return mapping, complete dismissal and repeat checks all pass. The inspected
post-fix render shows separate hint and button rows. No undo/redo operation was
performed; populated-history behavior is outside this layout regression's scope.
Owner preferences match, private application domain/demo root are removed, and
localization matches source. No matrix or GUI CI replay, install or land.

Private evidence: .build/undo-hint-targeted-regression.log,
.build/transient-sample-clean-de-full-mounts-g0-m30-probe.json and its raw log,
plus the scoped diagnostic render. GUI window was released after actual closure.

## Targeted product fix: View Options sheet height

The recorded M07 red source is byte-identical to current main for the controller
and caller: a fixed 450 pt scrolling accessory made mounted sheets 672/752 pt
high against 420/700 pt hosts. Immediately before presentation, measure the alert
and host, and subtract any overflow from the scroll viewport. Controls and format
reading remain intact; buttons stay outside the viewport. No response/default or
settings-persistence path changes. Fitting is presentation-time only, not live
resize/re-expansion, and a 44 pt minimum viewport does not promise arbitrary tiny
hosts can accommodate unlimited non-scroll content.

One targeted German launch at a 720x420 host exercised short and 255-character
names, three cancel/reopen cycles each. All six size checks now pass. Actual
mounted frames are 512x340 (short) and 512x346 (long), safely within the host and
screen; before/after renders confirm usable scrolling controls and visible buttons.
The debug pre-presentation measurements differ from mounted sheet layout:
752->420 with viewport118 (short), 832->426 with viewport44 (long). Do not conflate
these intermediate measurements with mounted frames or claim maximal viewport
utilization; AppKit relayouts on sheet attachment. The minimum binds in the long
fixture. The initial board relay used the older672/752 values for the intermediate
receipt and was promptly corrected; raw measurements are retained.

The full targeted profile remains native/wrapper exit 1, 70/76: only six check-3
observations report the seven already-ambiguous app-owned stacks. Size, geometry,
presentation, cancel, default, dismissal and repeat checks all pass six times.
Do not report the complete profile as green. All owner-preference, demo/private
application-domain cleanup and catalog witnesses pass. No settings were applied.

Evidence: .build/view-options-fit-targeted.log and
.build/transient-sample-clean-de-full-mounts-g0-m07-probe.json/raw log; private
render paths are retained with those receipts. Build passed. No broad matrix,
GUI CI, install or land; the native process ended and the GUI window was released.
