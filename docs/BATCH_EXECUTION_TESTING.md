# Pre-release batch: acceptance and limits

Trigger: the owner requested execution of six queued coverage/polish jobs after
repeated selection, search and transient UI reports. Queue staging was retired;
implementation and acceptance remain separate from queue state.

Write criteria before each sample. No public release, installed-app replacement,
keychain changes, permission grants or live provider/storage mutations are in scope.

## 1. Layout and listing boundaries

Sample: a real window, disposable folders with identically named files, five actual
content modes, minimum/default/wide sizes and representative pane ratios. A listing
must actually finish; requested mode is not evidence of delivered mode. Clip frames
must be positive, inside their pane, and panes must not overlap. A selected file must
survive resizing and mode changes. After explicit reveal its rectangle must intersect
the usable clip. Controls: zero-size, outside and partially clipped geometry must fail
the containment predicate. Queued creation selection/callback must not act in a
different directory, even when that directory contains an identically named file.
Broken design: discarded timeout, checking only outer frames, or a race test that
never delivers the destination listing. Drawer/provider connections and foreground
keyboard dispatch are not inferred from layout geometry.

## 2. Search

Require delivered actual modes and real folder scans for local semantics. Add
Unicode/punctuation, recursive hidden/package/symlink exclusions, binary/oversize
content and bounded-result controls. Rapid query/scope/reopen callbacks must reject
stale results. Injected whole-Mac index proves routing, not OS index completeness.

## 3. Transient surfaces

Inventory the production surfaces before changes. Geometry checks need long labels,
small/wide hosts and actual controls; oversized/clipped controls must fail. Verify
safe cancel/dismiss paths with fixtures. Do not infer native popup pixel quality or
external Accessibility from frame assertions.

## 4. Finder parity

Inventory shipped actions and missing native integrations. Each bounded addition
needs all-five-view menu presence, capability/selection disabled controls and real
disposable-file operation checks. Never equate a fake cloud provider with live cloud
sign-off; Services/Quick Actions depend on installed system providers.

## 5. Compiler warnings

Inventory fresh debug/release diagnostics, not historical counts. Reproduce semantic
warnings with a differing control before correcting them. No unchecked Sendable,
unsafe isolation assertions or blanket warning suppression. A warning gate must fail
on an introduced known diagnostic and distinguish first-party/vendor messages.

## 6. Visual evidence

Valid files alone are insufficient. Run good, blank, corrupt and clipped controls
through the same checker. Reject unusable captures and report why. Geometry and pixel
sanity do not establish human-approved native appearance. Never automatically accept
new golden images; environmental capture/native-speaker review remains pending.

## Results

### Release privacy/history gate — criteria before sampling

Trigger: Mission 53 still lacks a redacted tree/history release preflight. The
local gitleaks binary exists, but no repository scanner policy or wrapper does.
The sample must run the real scanner on disposable tracked repositories: a clean
noreply-authored tree/history must pass; a generated synthetic token must fail in
both current content and deleted-file history; a non-noreply fixture author must
fail without printing the address. Missing scanner, invalid/missing report, scan
failure, shallow history, ignored source changes, and redaction failures must fail
closed. Treat the exact LiveRemoteTests environment-variable expression as a
candidate false positive, never allow its whole file or every PASSWORD expression.
A real token on that line/path must still fail. Logs must contain only rule IDs,
commit IDs and counts, not scanner snippets, secrets, author identities or paths.

Only scale to the project's tracked tree/all reachable refs after each control
has a verdict and scanner delivery is established by actual report/status. No
history rewrite, credentials, keychain access, network upload or publication.
Bounded PII pattern checks are not comprehensive human identity/branding clearance;
any real finding is a release blocker to report, not permission to alter history.

Sample verdict: 12 initial real-scanner controls passed (2.37s). An expanded
control failed because its second mock invocation tried to create the same fixture
branch again; no project scan was launched from that failed design. Deliver the
mutation once and require two scan invocations plus the specific changed-input
failure. Restored 18 controls passed (3.38s): clean/secret/deleted/unmerged/current
inputs discriminate; noreply rejection, shallow/missing input/tool/report, scanner
stderr suppression, malformed/unredacted report, and delivered ref/content races
fail closed. Mutation and malformed-tool controls are injected; other scan fixtures
use real local gitleaks v8.30.1. Log assertions reject the synthetic secret, fixture
email and temporary path. The current LiveRemoteTests environment expressions
produce no finding, so no exemption was added; a token in that same path still
fails. These per-criterion verdicts permit the bounded local project scan, not
publication or comprehensive PII certification.

Actual project result is RED: 629 delivered candidate files, 890 reachable commits;
37 candidate-tree matches (34 absolute-user-path, three personal-email patterns),
41 historical matches (37 path, three email, one credential pattern), and zero
author/committer metadata findings. The historical credential-like match is a
literal in LiveRemoteTests, not an environment-variable expression; it is not
waived and is not claimed to be an active authentic credential without private
review. These are detector matches, not comprehensive proof of personal identity
or credential compromise. No cleanup/rewrite/publication was performed. Metadata
is intentionally withheld except counts and commit IDs; scanner reports are
redacted and protected by a private temporary directory. Broad privacy release
clearance remains pending; instrument acceptance is separate from a clean repo.

`make release-safety` requires the discrimination controls first. It remains
separate from routine app CI while historical release findings are unresolved.
Local unchanged-app verification passed build plus 15 XCTest and 779 Swift Testing
cases. Full app/native/packaged CI was not replayed for this Python/Make/docs-only
unit; its existing source-equivalent opener CI receipt remains separate evidence.

### Release-safety fixture triage — criteria before cleanup

The 37 current matches resolve to 34 static paths used as pure test inputs and
three example Google Drive account addresses (one production comment, two test
strings). Placeholder-account classification was checked without exposing values;
the cloud recognizer receives an injected home and identifies the provider by its
prefix, not the email domain. The path tests assert string parsing, precedence,
serialization and direct-child filtering; they do not require a real user home.
Replace only these examples with non-user fixture roots and reserved email domains.
Do not add scanner exceptions or rewrite history.

Sample criteria: relevant engine suites must preserve every existing assertion;
reserved examples pass the real gate, while existing private-path/email/token
controls still fail. The delivered candidate tree must fall from 37 to zero
matches; historical findings must remain visible. Any regression, an unexpected
historical green result or a detector weakened to obtain zero invalidates this
cleanup. History inventory also identifies two machine-specific configuration
paths and one credential-like literal; neither is automatically waived. Broad
release privacy clearance, human PII review and history authority remain separate.

Results: 71 existing engine tests in 12 suites pass after fixture substitution;
19 real-scanner/control tests pass, including reserved-example acceptance and
unchanged negative email/path/token controls. The candidate tree now has zero
findings (previously 37). Historical scope remains RED with all 41 matches intact
and zero authorship findings. The all-ref source review confirms 38 are synthetic
examples; it does not waive them. The other two path matches are obsolete
`.claude/settings.json` and `polaris.toml` machine configuration. The literal in
the old opt-in FTP test matches the provider's [public demo documentation](https://dlptest.com/ftp-test/)
and shared test-service host; only equality verdicts were emitted, never the
value. This is not evidence of a private-account credential needing rotation,
and no credential exemption was added.

History plan (not executed): keep an access-restricted backup outside all
release-scanned refs; coordinate every workbench/branch owner; review only the
obsolete configuration paths and credential literal, and handle benign fixture
matches with precise reviewed policy or neutral fixture replacements. The three
non-fixture historical commits have 851 reachable descendants/self across an
891-commit graph with 28 named refs at measurement. Those are an impact bound,
not a completed rewrite or a request to force-push. Commit hashes, tags, remote
tracking refs and agent references must be accounted for; original/private remote
history can retain objects even after a rewrite. Require explicit owner approval
before an isolated rewrite preview, any live ref mutation or remote rewrite.
Public visibility remains separately forbidden without manual approval. Until a
strategy is approved, keep the historical gate RED and current-tree cleanup green.

Local full verification: app build and 15 XCTest plus 779 Swift Testing cases pass;
the five live FTP/SFTP/DHT/Transmission opt-in skips remain explicit. Runtime code
is unchanged apart from canonical formatting of one loop; the CloudLocation
semantic edit is a comment, and all other Swift edits are synthetic test inputs.
No native/packaged full CI replay, installed-app change, credential action or
history mutation occurred for this unit.

### Always Open With — acceptance written before the sample

Trigger: selecting Choose in Always Open With appeared to do nothing. The popup
has no selection action; the old implementation defers the picker until Set.
Sample must mount the production sheet for an actual fixture selection, deliver
the popup's native target/action, and observe a visible NSOpenPanel immediately,
without pressing Set. No-picker-before-Choose is a differing control. Cancel must
leave the opener sheet usable and preserve rules. Missing selection, a popup not
mounted in the sheet, or an undelivered action invalidates the sample. All config
must be isolated in a strict temporary descendant. Never apply system-wide scope,
launch a chosen application, or mutate owner LaunchServices defaults in this test.
After the sample, expand to cancel/retry, candidate Set/persistence, and empty
candidate/custom selection state. Native picker acceptance and physical menu/key
input must not be inferred from injected URL state.

Baseline: the actual mounted fixture sheet passed selection, popup mounting,
no-picker-before-Choose, and cancel-no-save controls, but failed action delivery and
immediate picker presentation (4/6). This convicts the missing selection action,
not a beta OS change or a native picker failure. The opener source is identical in
the installed f1ce71d revision and the starting 539bc8f source.

Fixed sample passes 7/7. Expanded mounted control run passes 35/35: immediate
native picker, cancel/retry preserving app and scope, single-picker ownership,
application-only filters, disabled Set during picking/without an app, actual Set
saving file/folder rules to scratch config, and session-only rules leaving disk
unchanged. Empty candidate lists still permit Choose. Custom URL insertion and
deduplication exercise the shared completion-state helper with injected URLs, not
physical native picker acceptance; a subsequent real picker Cancel restores that
custom state. The system-wide scope is intentionally never applied. Sample
delivery, differing control, immediate-presentation criterion and inert Cancel
criterion all passed before the integrated gate was launched.

Integrated verification: `make ci` passed 15 XCTest plus 779 Swift Testing cases,
66 debug checks with one explicit cached-pixel capture skip and zero failures, and
11 current-host ad-hoc release-package checks. The new opener scenario passed 35/35
inside that run and configuration refusal guards passed 8/8. Fresh owned debug
warning inventory: 26 known fingerprints, zero new/unparsed; existing warning debt
was not removed by this change. Owner prefs/formats/openers fingerprints were
unchanged across the integrated run. No installed-app replacement, system-default
association write, or physical native-picker acceptance claim.

### Layout sample

Initial sample failed 10/148 checks: eight icon reveals and both cross-directory
creation assertions. Waiting for layout did not cure icon reveals: valid item frames
were thousands of points below the viewport while the clip stayed at y=0. Replacing
`scrollToItems(nearestVerticalEdge)` with minimal `scrollToVisible` made all 148 pass.
Creation selection/follow-up now carry their listing directory; mode swaps preserve
the queued operation rather than replacing its selection. Expanded sample passes
161/161 including geometry controls, 45 size/mode/ratio cells, origin callback-once,
and sidebar/preview/Drop Stack/terminal/torrent frame slices at two sizes.

Terminal and torrent toggles in this slice manipulate visibility only: they do not
start a shell or connect a daemon. Torrent detail, tab interleavings, combined drawers,
minimum usable interaction width and foreground keyboard acceptance remain open.
Native pixel appearance is not established by these geometry checks.

First full CI failed the historical no-nudge control (2px). Inspection showed its
second item ended at y=202 in a 200pt clip: the claimed fully-visible treatment was
not delivered. The control now uses 220pt and explicitly rejects a not-fully-visible
item before measuring. Production reveal also skips entirely when the item is fully
visible. All other debug scenarios passed in that failed run; packaging was not run.

Final layout verification: `make ci` passed 15 XCTest plus 766 Swift Testing tests,
20 debug E2E checks (including 161/161 layout, 49/49 interaction, 39/39 search,
132/132 Finder) and 9 signed release-package launch checks. Existing compiler
warnings remain; nonempty-render checks in this run are not native visual approval.

### Search sample

Four additional engine tests delivered Unicode/punctuation across a buffer boundary,
oversize/binary content, explicit-package-root control, indexed package/symlink
ancestor exclusion and a noncompliant index limit. Initial run failed exactly two
criteria: indexed ancestors leaked and whole-Mac results exceeded the requested cap.
The engine now checks all ancestors up to (not including) the chosen root and clamps
indexed whole-Mac results itself. UI coverage adds actual-mode delivery and visible
Reveal/dismiss/return navigation in all five modes; no default app is launched.

Final search verification: 14 engine tests and 59 UI checks pass; delivered unreadable
content and cancellation now have controls. `make ci` passes 15 XCTest + 772 Swift
Testing, 20 debug checks and 9 packaged checks. Live Spotlight completeness,
native folder-picker/default-app behavior and deeper resize/tab races remain open.

### Transient sample

Initial 44-check sample failed three drop-dismiss cleanup checks and two long-label
button-frame overlap checks. The drop context was never released on dismissal;
the production tracking scope now clears it with `defer` on every exit. Inspection
refuted a painted-button overlap: native 32pt frames include 5/7pt vertical alignment
insets; their 20pt alignment rects have 8pt separation. Corrected the instrument to
test AppKit's alignment geometry and added a known overlapping negative control.
No restyle was made to the accepted conflict UI. Real popover dismissal/default
button continuation and transfer cancellation/reopen/end lifecycle are exercised.

Menu tracking appearance/edge positioning, physical Escape/Return delivery, alerts
and native open/save panels remain environmental or future slices. An injected menu
presenter exercises production construction/cleanup, not foreground menu tracking.

Expanded transient sample passes 52/52, including repeated real popover default
completion, a geometric overlap control and transfer cancellation exactly once.
Final `make ci`: 15 XCTest + 772 Swift Testing, 21 debug checks and 9 signed
release-package checks pass. No physical key or native menu appearance sign-off.

### Finder slice

Inventory is in `FINDER_FEATURE_MATRIX.md`. Six baseline failures reproduced missing
named labels in all five shared context menus and enabled tag commands in a delivered
smart-result selection whose handler refuses writes. Reuse existing named-label
actions/xattr semantics in Tags; present mixed/all-selected states; gate tag/label
enablement consistently to local non-smart selections. Broader Finder functionality
and live providers remain pending exactly as the inventory states.

First integrated label sample passed 192/193, failing only column all-selected state.
Diagnostic showed `selection=[]` immediately after successful writes to both items.
Mechanism: `PaneController.reload` calls `ColumnBrowserController.setSortFormat`,
which reloaded tables without carrying selected names. Restore by names around each
column re-sort; add an explicit selection-preservation check in all five views.

Expanded Finder sample passes 198/198 (previously 132). Named-label presence,
mixed/all-selected states, real xattr writes/removal, selection retention and
empty/smart disabled controls pass across five actual views. Hiding Tags hides its
labels too. Deep drilled-column sort/refresh sequences remain a separate boundary.
Final `make ci` passes 15 XCTest + 772 Swift Testing, 21 debug checks (Finder
198/198, search 59/59, layout 161/161, transient 52/52) and 9 packaged checks.

### Compiler warnings

Fresh pre-change debug/release inventory on Apple Swift 6.4: 28 unique first-party
file/message fingerprints (line/column duplicates collapsed), not 28 warning sites.
Vendor/toolchain notices are counted separately. Installed Arrange-menu control
failed 2/4: Kind correctly checked, but None never checked because inferred
`Optional<GroupKey>.none` is nil. Explicit enum cases restore 4/4.

Trim completion now hops to MainActor; macOS-15-minimum async throwing export avoids
capturing a non-Sendable export session in a completion queue. The real generated
AAC fixture trims 3.00s to 1.00s; a missing-source control returns nil. Duration loads
and torrent content-type panels use modern APIs. Current host resolves the torrent
type to `org.bittorrent.torrent` with preferred extension `torrent`; picker behavior
on other systems is not inferred. The empty tracked test placeholder is excluded
from SwiftPM (preserved, not deleted); an unused pure URL binding is removed.

The exact warning gate has six controls, including a new semantic warning, ANSI
diagnostics, malformed owned diagnostics and vendor separation. It rejects the real
old logs with 13 removed fingerprints and accepts the fresh debug log with 12 known
fingerprints and no new diagnostics. Fifteen exact remaining exceptions explain why
they are still open in `scripts/compiler-warning-baseline.json`: this is an
incremental regression gate, not a warning-free claim. Interactive AVPlayer trimming
and Quick Look's live XPC thumbnail path remain environmental acceptance boundaries.

First full warning CI stopped at localization lint: migrating the export catch removed
the only use of the localized empty-error fallback. Restored that fallback for an
empty error description; retained the six translations. No later CI stage ran in
that failed attempt.

Final warning `make ci` passes: 15 XCTest + 772 Swift Testing, 23 debug checks
(including Arrange 4/4 and valid/missing trim controls), 9 packaged checks. Fresh
debug/release union has 15 remaining owned fingerprints (down from 28), no new or
unparsed diagnostics. Raw CI logs are retained under `.build/ci-*-build.log`;
remaining exceptions are explicit pending work, not suppressed compiler output.

### Visual evidence and trustworthy completion

Criteria, controls and failed attempts are in `VISUAL_EVIDENCE_TESTING.md`.
The old completion predicate fails three of six controls: PASS-before-exit-7,
PASS-before-final-FAIL and PASS-before-timeout-142 all falsely pass. Require a
successful exit and a final anchored, valid result token; preserve the existing
colon-delimited Gate A result. Ten completion controls pass. Seven report-policy
controls also pass after reproducing three blanket-SKIP failures: only the observed
browser-opacity boundary can skip, while unusable stable captures must fail.

The real ImageIO checker passes seven differing controls (good, black, white,
transparent, corrupt, truncated and wrong-sized). It checks complete decoding,
bounded dimensions/input, opacity and distributed contrast/detail. Settings/sidebar
and eight conflict content fixtures pass pixel sanity. Actual light/dark appearance,
English/German and default/long labels are delivered and logged; unsupported
appearance exits 64 without a PNG. Captures use isolated per-run directories, so
old global files cannot masquerade as new evidence. No new golden is approved.

First visual CI fails only the over-strict Gate A parser, not virtualization.
Second CI passes; final review then exposes overly broad skip classification.
Final `make ci` after that correction passes 15 XCTest + 772 Swift Testing,
60 debug E2E checks and nine signed release-package checks, with one explicit
browser-opacity SKIP (opaque fraction 0.746). Counts are harness checks, not
60 independently tested features; the final debug harness includes 20 product
scenarios plus reporting, capture and delivery assertions. Warning controls now
also cover test/script diagnostics (8/8); no baseline exceptions were added.

All six bounded implementation slices are locally verified and landed separately.
Broad Mission 53 remains open: native visual baselines/materials/placement,
physical input and environmental provider/storage acceptance, deeper transition
interleavings, the remaining Finder inventory and 15 warning fingerprints are not
closed by this batch. No installed-app replacement, publication, keychain changes,
permission grants or live provider/storage writes.

## Continuation: background menus and trustworthy warning delivery

Background context now exposes View/Arrange By through existing commands. The
263-check real-window matrix covers all five modes, all 25 delivered transitions,
checkmarks, rendered grouping versus None, unsupported grouping refusal and
inactive-pane isolation. It also convicts and fixes silently ignored hide/order
configuration: those hooks were extension defaults rather than protocol witnesses.
Saved duplicate/obsolete tokens are filtered while retaining first positions and
appending new defaults. Two added ordering controls pass; native popup tracking
remains unverified, and failed headless-enablement experiments are recorded in
`BACKGROUND_MENU_TESTING.md`, not retained as production fixes.

A forced whole-debug compile disproves the old cached warning inventory. Seven
redundant-unsafe fingerprints (eight static declarations) use compiler-checked
Swift 6.4 statics with unchanged older-toolchain fallback. Two TorrentKit C-string
fingerprints are fixed with bounded decoding and five differing controls. Twelve
unchanged SecureTransport device-bridge fingerprints are explicitly inventoried
as pending migration debt requiring paired-device acceptance. The original strict
inventory criterion failed; its measured debt amendment is recorded in
`COMPILER_STATICS_TESTING.md`. CI now forces fresh warning delivery every time.

Full integrated local CI exits zero: 15 XCTest tests, Swift Testing's 779-case run
(five live opt-in tests explicitly skipped), 61 debug E2E checks plus one explicit
browser-opacity skip, and 9/9 current-host packaged release checks. The emitted
debug/release warning union has 27 exact known fingerprints, zero new/unparsed;
this is not a warning-free claim. Mission 53 and the remaining configuration-hook,
native visual/tracking, older-SDK and environmental boundaries stay open. No
installed-app replacement, publication, keychain changes or permission grants.

## Continuation: delivered content preferences and constructor boundaries

The optional-hook audit reproduces ignored color rules, list formats and middle
clicks: methods existed only as extension defaults, so existential calls selected
no-ops. Four requirements now use existing implementations. Delivered styling also
convicts selection-clearing display reloads across five modes; scoped shared
preservation retains compact native selections, scroll and expanded/drilled state,
without rebuilding directory rows or scheduling unrelated metadata work. New tabs
previously reset six content preferences; constructor and live application now use
the same path. The real-window matrix passes 132/132, including six formatter
combinations, native middle-button events and actual new tabs, menu inheritance,
expanded Tree child identity, Column no-redrill, nonzero-scroll visible/offscreen/
empty cases, multiple selection and group-header offsets. Refusal controls pass
2/2 before browser startup; the scenario owns its temp config and cannot pollute
other E2E scenarios. See `CONTENT_CONFIGURATION_TESTING.md` for preregistered
criteria, instrument errors, red controls and confidence limits.

First integrated CI fails its non-executable guard wrapper and transient lifecycle
checks. The wrapper is corrected. Parent/component/restored comparisons do not
establish a stable popover mechanism; no speculative production fix is shipped.
Improved DEBUG failure-state telemetry remains, and the intermittent observation
stays open. Final restored full CI exits zero: 15 XCTest, 779-case Swift Testing run
(five explicit live skips), 63 debug checks/one browser-opacity skip/zero failures,
and current-host package 9/9. Existing feature matrices remain green; fresh warning
union is 27 exact known/zero new/unparsed, not warning-free. Gallery coloring,
Column density/fonts, native visual/physical/lifecycle acceptance and older-SDK/
provider/device boundaries remain open. Missions 4/6 are explicitly owner-held.
No installed-app replacement, signing credentials, keychain changes or publication.

## Gallery parity and first configured view continuation

Owner requested resuming Mission 53 after relaunch. Gallery lacked the shared
filename-rule renderer entirely; a delivered sample failed only the matching style
(12/13), with negative and selection controls passing. Gallery now uses the same
`FileColorStyle` and equality-guarded appearance-preserving setter as Icons.
Color-only/font-only/precedence/no-op/font-size controls pass, as do horizontal
visible/offscreen/empty/multiple-selection rule-change regressions.

New-tab expansion initially had invalid default-format inputs; those red results
are retained in `CONTENT_CONFIGURATION_TESTING.md`. Once the registered
`view.useAsDefault` command, effective default and absent folder override were
proven, a real initialization bug remained: the first configured reload overwrote
the saved Gallery default with initial List under a navigation-only sticky rule.
Sticky mode now applies only after the first configured folder-format resolution.
Small sample 29/29 proves initial default, later sticky navigation despite a
differing global default, and explicit saved-folder precedence. Expanded matrix
176/176 covers all five initial view modes and retains earlier preference checks.
Both scenarios are mandatory with separate disposable configuration roots.

Fresh full local CI passes: 15 XCTest and 779 Swift Testing cases (five explicit
live skips), 64 debug scenarios/one browser-opacity skip/zero failures, current-host
package 9/9, and 27 exact known/zero new/unparsed warning fingerprints. New matrix
176/176 and focused sample 29/29 pass inside mandatory E2E; transient controls also
pass 52/52 without implying a lifecycle fix. Normal commit hooks and land follow
this recorded CI closure. Missions 4/6 remain held; Gallery Quick Look caption/
physical visuals, Column font/density, intermittent
popover causation, real Settings defaults versus saved global formats, and broader
native/provider/device acceptance remain outside this slice. No install/keychain/
permissions/signing/publication action.

## Settings global-default consistency continuation

Owner selected Mission 53 task 30. Actual Layout popups changed and persisted
Preferences, while unconfigured new tabs still resolved List/name/ascending from
the separate FolderFormats store. A delivered differing-control sample failed
42/52: forward defaults/file order and reverse command-to-preferences/mounted UI
agreement failed, while input actions, name-ascending and override controls passed.
Early selection/format-input mistakes are retained in CONTENT_CONFIGURATION_TESTING.

Settings now updates only global view mode, sort key and direction. The existing
menu command synchronizes the Settings callback model and persisted preferences.
Startup loads preferences first, preserves an existing saved global format, and
uses preference defaults only when formats are absent. Exact/subtree rules and
unrelated grouping/hidden fields are retained; sticky navigation is unchanged.

Sample 64/64, date-sort 86/86 and startup-store 82/82 pass before expansion. The
full five-view/five-sort/two-direction matrix passes 588/588 with real mounted
controls, file ordering, persistence, reverse commands, subsequent edits and three
owned-window startup cases. Fixture date ties caused an explicit red discriminator,
then were corrected before scaling. Empty references cannot pass sorting checks.
Four early root-refusal controls cover both content and Settings flags; the new
mandatory scenario has its own disposable configuration root. Full local CI and
normal commit hooks remain the acceptance gate before landing. No install,
keychain, permission/signing credentials or publication action; Missions 4/6 held.

The first full Settings CI passed but exposed an existing packaged-probe safety
hole: release builds ignored the debug config override and startup rewrote normal
owner prefs. No before snapshot exists, so value changes cannot be quantified and
no owner values were restored. Explicit release-test mode now requires a strict
temporary config root before startup and never falls back to owner configuration;
normal release behavior is unchanged. Refusals discriminate against a non-refusing
synthetic control; debug6/6, release2/2 and isolated package11/11 pass. Owner prefs/
formats hashes remain unchanged across the isolated package sample and final CI.

Final integrated CI exits zero:15 XCTest,779 cases/161 suites with five opt-in live
skips; debug65 pass/one browser-opacity skip/zero failures; Settings588/588 and all
existing feature matrices pass; isolated package11/11. Fresh debug build59.79s,
344 owned-source compilation lines,26 exact known/zero new/unparsed fingerprints;
including the fresh release-isolation build retains27 known, not a warning-free
claim from the warm final package log. Normal commit gates and land follow. No
install, permission/credential changes, publication or claimed popover fix.
