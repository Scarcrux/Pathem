# Content configuration: acceptance before the sample

Trigger: the menu witness bug prompted an audit of adjacent optional hooks.
Source inspection finds four extension-only defaults for color rules, list display
formats, middle-click enabling and its new-tab handler. Concrete implementations
exist but PaneController calls through the shared content existential. This is a
delivered-behavior hypothesis until the real window shows it.

Criteria written before the baseline:

- Use disposable files and explicitly isolated configuration. Missing or non-temp
  configuration roots must exit 64 before browser startup, not touch owner state.
- Deliver a sized real window, actual requested content and complete listings.
  Test existing supported color renderers (List, Icons, Columns, Tree); Gallery's
  missing color implementation remains an unsupported boundary, not a new feature.
- Read actual filename fields: matching alpha text must get the configured RGB and
  bold/italic traits; beta must not. Disabling or clearing a rule must restore the
  default. A no-op match must not force a style. These are differing controls.
- List size/date cells must follow all decimal/binary and relative/short/medium
  combinations. Compute reference formatter output independently and first require
  distinguishable size/date controls. Do not infer delivery from private settings.
- Deliver a native middle-button-up event at the actual folder row through the
  installed table. Require exactly one real tab at the folder URL on the originating
  side. Disabled preference, a file and empty space must not open tabs. Record the
  real event button and hit row; no global event posting or Accessibility grant.
- Apply settings through the browser's actual preference application and record the
  isolated persisted values. View swaps must retain settings when returning to
  supported content. Newly created tabs must inherit the same color, format,
  middle-click and menu hide/order configuration, not reset to defaults. This is
  a separate constructor-boundary hypothesis until a delivered tab proves it.
- Inactive panes/tabs must not lose their listings or selection. Per-pane overrides
  must not leak; browser-wide preferences should intentionally reach both sides.

Start with List/Icons only. Missing matching style, ignored formats or absent real
tab delivery is red. Expand only after positive and negative controls discriminate
and the actual fixtures/events/settings are logged. Then run full local CI and
record skips separately. Native physical input, popup tracking, Gallery coloring,
older SDKs and real provider/hardware acceptance remain outside these claims.
Missions 4/6 are owner-held; no publication, signing credentials, keychain or install.

The initial instrument draft does not compile because it assigns the derived,
read-only `Preferences.defaultFormat`. Correct the instrument to set the underlying
default view mode before interpreting any product behavior. Missing event target
fields must fail delivery explicitly, not silently become an empty-space control.

First sample is red 27/47. Matching styles and binary/short/medium formatting are
ignored, while fixtures/reference controls/persisted preferences are delivered.
The middle-click instrument is itself invalid: Cocoa's factory produces button 0,
not button 2, so its tab outcome cannot convict a product handler yet. Correct the
real CGEvent button field and rewrap it as NSEvent; require its actual button and
hit row before dispatch. Never globally post input. See Apple's
[button-number contract](https://developer.apple.com/documentation/appkit/nsevent/buttonnumber)
and [CGEvent initializer](https://developer.apple.com/documentation/appkit/nsevent/init(cgevent:)-4igjn).
The immediate inactive-pane checks also fail; first distinguish in-flight preference
reloads and URL spelling from stable selection loss before attributing a mechanism.

Corrected sample is red 35/47. All four native middle events now deliver button 2,
the intended row (including empty-space -1), and the real window ID. Enabled folder
opening still produces no tab, while disabled/file/empty controls differ correctly.
Color/format failures persist. Add exactly the four missing protocol requirements,
retaining unsupported-view defaults. This makes existing concrete implementations
witnesses without inventing new behavior. Stable inactive selection is still empty
after three seconds; before a production selection change, require initial delivered
selection and isolate style, folder-size, click-behavior, theme and full-preference
steps, resetting a proven input before each. No unconvicted selection patch.

After the witness change all color/format checks pass, and the instrument sees a
created tab but its raw URL-hint comparison rejects the folder spelling. Compare
standardized filesystem paths (directory hints are not identity), log actual tab
counts/target, and always close newly created fixture tabs even on a failed check.
Selection trace passes 11/13: initial selection is delivered; style and full
preferences lose it, while folder-size/click/theme controls keep it. Before fixing,
further isolate table reload, row-height assignment, formats and color-rule updates.

Narrow trace is red 16/21: raw table reload, formats, color rules, style and full
preferences clear proven selection; same row-height assignment and the other
controls preserve it. The corrected folder path check now proves exactly one real
tab on the left, no right-side tab, and restores the original tab. The main sample
is red only on inactive selection (46/48). Wrap the three convicted display-only
reloads with compact index/viewport preservation; row identity/order are unchanged,
so do not rebuild rows, trigger metadata refresh or copy every selected FileEntry.
Retain the raw native reload as a host-specific **expected bad** diagnostic control;
the fixed application methods must differ and preserve the delivered selection.

The fixed diagnostic trace passes 21/21, including the expected-bad native reload;
the List/Icons sample passes 48/48. Before expanding, add delivered left-side
selection controls in each mode and a small 150-file viewport sample: visible
selection through a real density change, intentionally offscreen selection without
yanking back, empty selection without a scroll reset, multiple selection and a
group header offset. Require actual nonzero scroll origins and differing selection
visibility before interpreting preservation. Then run the five-mode/new-tab matrix.

The extended List/Icons sample is red 60/61: all viewport controls pass, but Icons
loses its proven selection. The combined runner incorrectly continued into the
full matrix despite that sample failure; this is a validation-order error, not a
justified green expansion. That exploratory matrix is red 103/112: four other
views lose selection and fresh tabs ignore five settings checks (color, format,
hidden/order menus, middle click). Do not repeat the full matrix until the narrow
sample is green. First isolate style/color/formats per individual view with proven
input selections; fix only convicted reloads. Constructor inheritance remains a
separate observed failure to address after selection controls pass.

Individual-view probes convict exactly these reload paths: Icon style/color (8/10),
Gallery style (9/10), Column color (9/10), Tree style/color (8/10). Format no-ops in
unsupported views preserve the proven selection. Use shared display-only table/
collection preservation only in these setters and the proven List setters. Keep
tree expansion and suppress Column's drill/preview callbacks during restoration;
an appearance update is not a navigation gesture. No blanket replacement of other
reload paths. Add a distinguishable constructor style control (font 17 and
comfortable density) before the next fresh-tab sample; default-looking fonts cannot
prove inheritance. Gallery color support remains unimplemented, not falsely claimed.

After scoped shared preservation, the narrow List/Icons plus viewport sample passes
61/61 and each individual-view probe passes 10/10. Before the next expanded sample,
require an actually expanded Tree child selection and a drilled Column selection
without redrilling/preview navigation during styling. Add nonzero-scroll collection
controls for Icons/Gallery (visible, intentionally offscreen, empty selection) to
test their helper's viewport behavior, not just root selection. Run the narrow
sample first and abort the runner on failure before any expanded invocation.

The extended narrow sample passes 71/71. Expanded sample is red 123/131: Tree
expansion and both collection viewport sets pass, while all six fresh-tab preference
checks fail. Source confirms the constructor only pushes selected header settings,
not the content preference path. Extract that already-tested path and apply it to
new panes as well as existing ones. Two Column checks also fail because the probe
never activates the newly mounted child column: displaying it does not make it
active. Require the actual mounted three-row child table and select its alpha row
through the existing column handler before interpreting retention. No production
drill change is justified by that undelivered input.

Corrected narrow sample passes 71/71 and expanded matrix passes 132/132. All six
constructor checks now differ from the rejected defaults (including font 17,
comfortable density and exactly two real tabs after the inherited middle action).
Expanded Tree child identity and drilled Column selection/outer scroll are retained.
List, Icon and Gallery visible/offscreen/empty scroll controls pass; multiple List
selection and the grouped header offset pass. Actual menu hide/order and persisted
temporary preferences are checked, not inferred from the controller's private cache.

Before final CI, wire the full matrix and both exit-64 root-refusal controls into
mandatory debug E2E. Give this preference-writing scenario its own temp config
subdirectory so it cannot contaminate other scenarios. Full CI must freshly compile
owned sources, pass the unchanged exact warning gate, run all unit/debug/package
checks and retain environmental/capture skips explicitly. Native visual goldens,
physical input/popups, Gallery colors, arbitrary deep transition interleavings and
older-SDK/device/provider acceptance remain separate boundaries.

First full CI exits 2 (make reports its recipe's exit 1), not green. Fresh gate is
26 exact known/zero new/unparsed; 15 XCTest and 779-case Swift Testing run pass.
New matrix passes 132/132, but its refusal wrapper exits 127: the Perl timeout
launcher execs an executable and cannot resolve a shell function. Give that wrapper
an explicit executable-script mode, preserving the actual exit-64 checks.
Existing transient UI reports 48/52; reproduce its default-action/continuation
failures in an isolated launch before attribution. No foreign-process cause inferred.
Packaged stage was not reached in this failed CI. Inputs can change only now that
the run is terminal; rerun the full gate after narrow refusal/transient checks pass.

Executable refusal wrapper now passes 2/2. Isolated transient launch repeats 48/52:
initial presentation and three reopens pass, cancellation plus three default-action
completion checks fail. These are continuation/lifecycle checks using a real
button action, not physical keyboard tests. Before changing production behavior,
trace whether the popover/continuation is still present and whether the waiting
task actually completes. This distinguishes native closing from async-result
scheduling and stale-popover identity; no foreign activity is a causal explanation.

Trace shows each failed action leaves the popover shown and its continuation still
pending, so this is not merely an already-resumed task failing to run. The probe's
readiness signal is suspect: Apple documents
[`isShown`](https://developer.apple.com/documentation/appkit/nspopover/isshown)
as true from the show invocation, while
[`didShowNotification`](https://developer.apple.com/documentation/appkit/nspopover/didshownotification)
occurs after onscreen animation completes. Add DEBUG-only observation of that real
delegate event, keyed to the current popover identity; require it before actions.
Do not disable production animation, fabricate readiness or change button handlers.
Whether that criterion resolves the failure must be measured, not assumed.

Presentation-event attempt is red 47/52 and does not consistently deliver its own
readiness criterion; do not claim an animation fix. Scoped owned changes are
checkpointed while rebuilding unchanged parent `9f200fc` in the same workbench.
Parent transient probe passes 52/52. Restore the checkpoint and compare the
original readiness predicate while omitting only constructor content preferences.
This is a temporary diagnostic control, not a shipped rollback or suppression.

Omitting only constructor delivery restores 52/52 under the original probe,
convicting that initialization interaction rather than a foreign timing explanation.
Before choosing a fix, use temporary DEBUG component controls for constructor
style, formats, menus, colors and middle-click enabling separately. All other
preference application remains unchanged. Require the failing component and its
working contrasts; do not ship these bypasses or the unsuccessful readiness change.

All five component controls pass 52/52. Two full/default-constructor repeats also
pass 52/52, weakening the constructor-cause inference: that earlier comparison is
not a stable causal reproduction. Remove all bypasses and presentation-event
changes. Keep only DEBUG pending-continuation state plus detailed failure output
to help a future failure name its mechanism. Production popover behavior and
animation remain unchanged; no animation or stale-identity fix is claimed.
Rerun the restored configuration matrix/refusal/lifecycle controls before CI.

Restored code (no component bypass, no presentation-finished override) passes
two independent transient launches 52/52, the configuration matrix 132/132, and
executable refusal controls 2/2. Production popover lifecycle is unchanged. The
earlier 48/52 observation remains unexplained/intermittent and is recorded as open
native lifecycle work, not converted to SKIP or called fixed. The restored differing
controls justify another full CI attempt; code inputs are frozen for that attempt.

## Final verification

Restored full `make ci SWIFTPM_FLAGS='--build-system native --jobs 2'` exits zero.
Fresh debug compilation completes in 67.77 seconds and recompiles 323 owned-source
entries. Debug/release union: 27 exact known warning fingerprints, zero new and
zero unparsed; no baseline exception added by this slice. Unit run: 15 XCTest,
Swift Testing's 779 cases/161 suites, with five opt-in FTP/SFTP/DHT/Transmission
tests explicitly skipped. Debug E2E: 63 passed, one explicit browser-opacity skip,
zero failures. Mandatory configuration matrix: 132/132; refusal guards: 2/2;
transients: 52/52. Existing search 59/59, Finder 198/198, background 263/263 and
layout 161/161 pass. Packaged current-host release: 9/9, including signature,
launch and visible window. This is not universal/distribution acceptance.

The initial failed CI and intermittent transient observations above are retained;
there is no production popover fix, animation override, diagnostic bypass or new
SKIP. Native lifecycle causation remains open with improved DEBUG failure context.
Gallery coloring and Column font/density support are not implemented by this slice;
list-only size/date/middle-click capabilities remain bounded as before. Physical
input, native appearance/goldens, older SDKs and device/provider boundaries stay
open. Missions 4/6 remain owner-held. No installation, keychain, permission grants,
signing credentials, repository visibility change or publication.
