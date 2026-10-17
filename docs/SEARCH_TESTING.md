# File search acceptance criteria

Trigger: users expect keyword matching in filenames or contents with an explicit location;
the old Cmd-F silently ranked folder entries by semantic similarity and had no result UI tests.

Criteria written before implementation validation:

- Filename mode finds a mixed-case keyword in a real filename; a content-only match must fail.
- Contents mode finds a keyword in a neutral-named text file; a name-only match must fail.
- This Folder and a selected other folder stay within that root. The subfolder toggle is honored.
- This Mac routes to Spotlight with the selected filename/content predicate. Hermetic tests assert
  routing with a fixture backend; they do not claim that the live OS index is complete.
- Empty/clear, no matches, loading, backend error, result limits and skipped reads are distinguishable.
- Debounced typing, mode/scope changes, close and reopen cannot adopt stale results or actions.
- Enter and arrow keys choose a real result; Reveal selects it after async navigation, without
  replacing the underlying pane's listing while the user is still typing. Open uses normal file opening.
- Toolbar and Cmd-F reach the same search UI; column mode is supported; command search stays separate.
- A real-window layout check and screenshot show readable controls and result columns at minimum size.

Negative controls (name-only, content-only, out-of-scope and deliberately delayed stale results)
must traverse the same engine/controller as their passing counterparts. Matching only a success
marker, accepting an empty fixture, or asserting a helper without exercising the controls fails
the design. The deterministic sample must pass these criteria before running the ordinary broader suite.

Validation notes: the initial sample correctly failed Cmd-F because saved-search registration
removed every `search.*` command, including the built-in entry point. Ownership-scoped cleanup
fixes the demonstrated cause and the regression now passes. The first 32 real-window checks and
8 hermetic engine tests passed, including all positive/negative matching controls. Live capture
was attempted twice and `screencapture` exited 1; cached AppKit rendering also produced invalid
black/white controls and was rejected. Scripted layout assertions pass; visual screenshot
approval remains unproven and is not counted as a passed criterion.

Final local CI: 2026-10-09 `make ci` passed localization in all six catalogs, 9 XCTest tests,
762 Swift Testing tests, 18 debug product scenarios (including 39/39 search UI checks and the
existing 49/49 interaction checks), and 9 signed release-package/launch checks. No public
release, installed-app replacement, or keychain changes were performed.

Direct folder search excludes hidden entries and package internals, does not follow symbolic links,
and does not read online-only files. Contents mode scans UTF-8 text up to 32 MiB per file and merges
scope-checked Spotlight document matches (PDF/Office and installed importers); omissions and an
unavailable document index are reported. Whole-Mac contents search uses Spotlight's indexed text.
Live Spotlight, OS folder-picker approval/physical interaction,
and default-app interoperability remain environmental, not hermetic coverage claims.

## Search presentation / native folder-picker boundary

Criteria written before sampling: the picker must be a visible real NSOpenPanel
attached to the search panel, reached through the scope popup's installed action.
Cancel in the same presentation is the differing control: return to This Folder
and remain idle for an empty keyword. Re-present search for another root with
This Mac while that picker is still open. Confirm the new root/scope/query is
delivered and the backend produces a distinguishable Mac result. Then deliver the
old picker's native Cancel completion and require the newer scope, results and
callbacks to remain unchanged. Count completion receipt explicitly; disappearance
or a fixed delay alone is not evidence that the handler ran.

An undelivered popup action, absent/unmounted picker, missing completion receipt,
or an unexecuted replacement backend invalidates the sample. The native picker
may be cancelled but must never approve any user folder. All roots/configuration
are disposable; Open callbacks record URLs rather than launching an application.
No physical menu/key dispatch, live Spotlight completeness or default-app behavior
is inferred from this controller/API-level session test. Do not change production
behavior before the baseline convicts a mechanism. Extend the close/reopen and
mode/scope matrix only after the bounded control/sample has a verdict.

The existing deliberately delayed query/reopen controls also require backend-start
and controller-response receipts, not a 250ms/800ms elapsed-time assumption. Both
old and new responses must actually reach the controller before comparing results;
the cancelled old response must return after reopen before claiming it was rejected.
All receipt instrumentation is DEBUG-only and does not change release behavior.

2026-10-13 bounded baseline: debug build passed, then the native sample exited 1,
11/14 checks passed. Every delivery criterion passed: installed scope action,
mounted directory-only sheet, ordinary Cancel completion/control, replacement Mac
backend, and stale native Cancel completion receipt. The three invariants failed:
scope changed from This Mac to This Folder; `mac-current` became `folder-current`;
Open called the replacement callback with the wrong URL (the old callback was not
called). The completion had no presentation/picker ownership check and unconditionally
called `optionsChanged()`, which re-searched the newer keyword using the reset scope.

Treatment: retain the active picker, relinquish its identity before cancelling it
on present/dismiss/window-close, and reject a completion not belonging to that
picker. Refuse duplicate picker actions while one is owned. Query generations
remain separate: typing/options in the same presentation must not accidentally
invalidate an otherwise legitimate picker. The treatment sample also reads the
replacement root from the visible location label before delivering This Mac's
installed scope action. Validation results follow only after actual execution.

Treatment bounded verdict: build exit 0; native sample exit 0, 16/16. All delivery
and differing-control criteria passed, and all three former invariant failures
passed with `mac-current` preserved. Added root-label and actual Mac-action checks
also passed. This validates the bounded instrument, not physical interaction or
whole-Mac index completeness.

Next extension criteria (written before execution): duplicate installed popup
actions must retain the same attached picker without completing/replacing it.
Both the actual window close and search-panel Cancel action must cancel an owned
picker; its completion must arrive, leave the panel closed/idle, and not overwrite
a newly presented query/root. Ordinary picker Cancel after an already-selected
fixture folder must retain that folder and the current Contents/subfolder options,
and really re-run that request. The initial extension design attempted native
acceptance of only a disposable fixture root (never a user directory). Test the
normal query and close/reopen response receipts
in the full search suite too. A missing delivery or root outside the disposable
fixture invalidates the test; do not bless a visually disappeared sheet alone.

Extension instrument failure: the first extended build passed, but the test exited
134 when `acceptedPicker.ok(nil)` raised `NSGenericException`,
`-[NSSavePanel ok:] : not implemented`. This was a harness action, not a production
search failure; the earlier checks were not emitted before the abort and are not
counted as passes. Stop native acceptance via this API. Revised design seeds the
selected-folder precondition through the existing DEBUG fixture helper, verifies
the delivered root/options, then drives the real Choose button and native Cancel
completion. Ordinary Cancel on a new picker (must change Other to This Folder)
already discriminates a guard that rejects all completions. Native acceptance
remains environmental/unproven; fixture seeding is not claimed as OS acceptance.

Revised extension build and native sample pass, 37/37. Both actual window `close()`
and panel Cancel actions deliver the old picker completion while the re-opened Mac
query retains its own results. Duplicate action retains the original picker;
real Choose/native Cancel preserves the seeded Contents/nonrecursive folder request.
Full search now passes 99/99 (previously 59), including four additional explicit
backend start/response checks and 36 native session checks. Claude's source-only
peer review found no blocking issue in the ownership/cancellation ordering.

Full local `make ci` is **not green**: fresh build/warning inventory (no new warnings),
15 XCTest and 782 Swift Testing cases pass. Debug E2E finishes 65 passed, 1 skipped,
1 failed; search passes 99/99 there too. The mandatory pane-configuration scenario
fails 158/176, also observed by Claude on unchanged main before this search unit;
its tab-ownership hypothesis is tracked separately as Task 39, not treated as proven
or waived. The normal logger retained the failure tail, not every failed check name.
Browser cached-pixel capture is explicitly skipped (native appearance unverified).
The make process exits 2 and does not reach packaged E2E. Concurrent Claude packaging
was recorded as a possible resource confound, never inferred as the failure cause.
No search installation, keychain/credential operation or public release was performed.

## Task 40: cancelled picker must retain the previous scope

Criteria before baseline: with no selected Other Folder, search for a real keyword
in This Folder (differing control), initially presented This Mac filename mode, and
This Mac contents mode delivered through the installed scope/mode popup actions.
Use a scope/mode-distinguishable injected backend, require initial results and
request receipt, then select Other Folder through its installed action. The visible
NSOpenPanel must be attached and directory-only; prior results/actions must clear.
Deliver native Cancel and require an explicit completion receipt and re-search
receipt. Scope, mode, keyword, results and the real Open button's recorded callback
must retain their pre-picker meaning. This Folder must remain Folder; Mac must
remain Mac, so indiscriminately selecting Folder fails the Mac contrasts.

An absent picker/action/backend/completion invalidates the instrument. Open callbacks
record only fixture URLs; never approve a user directory or launch an application.
This is native controller/action coverage, not physical popup interaction or live
Spotlight completeness. Source-only preparation waits for Claude's actual current
updater-isolation native/compiler terminal before running. No production repair
before the baseline convicts the scope transition; no packaged probes before the
peer's updater isolation repair is accepted.

Baseline build exit 0; native sample exit 1, 28/36. All initial action/options/backend,
native sheet, action-clearing and completion receipts pass; the Folder filename
control passes. Both Mac cases fail exactly scope restoration, original-scope
request, results and Open URL (eight invariants). Mode is retained. Cause: the
owned completion selected This Folder whenever no Other Folder was remembered,
without considering the scope from which the picker was opened.

Treatment tracks the last committed popup scope (including initial Mac presentation),
captures it before the pending Other choice and restores it on Cancel. Accepted
native selection still commits Other Folder; re-choosing an existing folder keeps
Other on Cancel. Existing stale-picker ownership remains unchanged. The three-case
regression is mandatory in normal search E2E, not only an optional sample. Verify
the bounded sample before expanding scope/action/keyword cases or ordinary CI.

Treatment build/sample both exit 0, 36/36; the eight former invariant failures pass
with native completion and backend receipts still required. Design is discriminating:
the Folder control passed on old source while both Mac cases went red. Before the
ordinary full suite, expand to six cells: both filename/contents modes for This Folder,
and both modes through each Mac entry path (initial presentation or installed scope
action). All six must retain their original scope/mode/query/results/Open URL. This
does not change native-approval or physical-menu limitations. Existing session checks
must also retain Other Folder's nonrecursive Contents request after re-choose Cancel.

Expanded build and native matrix exit 0, 72/72; ordinary full search exit 0,
170/170 (previously 99). All six scope/mode/entry-path cells pass with actual native
Cancel and re-search receipts, including prior committed Other Folder retention in
the existing session controls. All Open callbacks in the new cases record the
original-scope result. No native approval/live index/physical-input claim is added.
Whole CI waits for Claude's strict archive failure instrument to be verified/landed
so another disk-image failure retains context rather than being silently retried.

Final local `make ci` exits 0 after adopting verified peer archive instrumentation
673eeaa/4a3bdb4 and updater isolation c2cfec5. Fresh debug warning inventory is 15 exact
known, zero new/unparsed; 15 XCTest and 782 Swift Testing cases pass (opt-in live
network tests retain their explicit skips). Debug E2E is 66 passed, one standing
cached-browser-pixel skip, zero failures; search is 170/170 and ContentPrefs 204/204.
The strict archive/disk-image scenario passes 10/10 in this run. Packaged current-host
arm64 ad-hoc checks pass 14/14, including the actual updater-disabled release-probe
receipt. No owner-default cleanup, installation, signing credentials, keychain,
public release or history mutation was performed by this lane.

The prior Mac-Cancel baseline 28/36 and earlier unrelated CI negatives remain above.
One green CI does not settle Task 39's original intermittent attribution or Task 42's
disk-image Resource busy cause; both retain diagnostic receipts/open tracking. The
new single-result cases validate scope/mode routing, not arbitrary multi-result
selection/viewport retention across a re-query. Native appearance, physical input,
native picker approval and live Spotlight completeness remain separate boundaries.

## Task 43: keyboard, explicit Reveal and real pane-viewport continuation

The mandatory native suite now includes all-five-view/both-pane nonzero viewport
and selection controls, real field-editor queries, matching/no-match/clear/reopen,
actual accepted-listing and backend receipts, nonfirst-result Return/keypad Enter,
origin-pane visibility/ownership, and controlled old/new response/navigation races.
It passes **465/465** after three convicted repairs: keypad Enter activation,
post-listing explicit Reveal scrolling (without changing generic restoration),
and non-activating programmatic Column selection. Search automation now requires
its own temporary configuration root before startup. See
[SEARCH_INTERACTION_MATRIX.md](SEARCH_INTERACTION_MATRIX.md) for criteria, the
red sample/counterfactual, corrected instrument and exact confidence boundaries.
This does not approve native visual baselines, OS picker acceptance, live Spotlight
completeness, physical input, or external default-application interoperability.
