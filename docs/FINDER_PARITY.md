# Finder settings parity

Trigger: the owner supplied Finder's List View Options and requested all nine audited gaps.
The source default for dates was already relative, but the owner's persisted `medium` value
overrode it. That local preference was changed separately; do not migrate explicit user choices.

## Acceptance criteria (written before the sample)

- Old format JSON loads without losing rules; new per-folder options survive round-trip.
- Exact/subtree/default scopes retain their existing precedence. Explicit non-relative dates
  remain selectable; Today/Yesterday rendering is checked separately from the stored enum.
- Real native controls apply to the originating folder, never a newly activated pane.
- List columns, icon geometry, preview toggles and label position reflect delivered options;
  switching folders and view modes does not leak another folder's overrides or jump the viewport.
- Metadata reports real available data; unsupported sharing/version fields must not be invented.
  A plain local file is a contrasting empty/unavailable control.
- Filename suggestions never overwrite typing or a newer/dismissed rename. Rename stays usable
  without Apple Intelligence. The original extension is retained by suggestions.
- Extension-change warnings gate the actual operation; Cancel must leave the file unchanged.
- Trash cleanup is opt-in, never infers age from modification/creation dates, never traverses
  links or arbitrary configured roots, and only removes objects whose actual Trash date is older
  than 30 days. Young/unknown-age/link/outside-root fixtures must survive. No owner Trash tests.
- Focused tests/build and native UI controls pass before broader CI. A red result is retained,
  not erased by loosening assertions. Full hardware/receiver integration remains separate.

## Follow-up audit

After implementing and verifying the parity batch, audit asynchronous UI ownership, settings
delivery, remote/local operation boundaries and regressions. Record evidence, mechanism and
confidence; do not mix speculative fixes into this feature batch.

## Implementation and sample evidence

- Added optional, bounded `ViewFormat.options` for dates, text, icons, previews, spacing,
  label position, columns/widths, folder sizes and the Home Library exception. Existing
  exact/subtree/default precedence is retained. Explicit dates are not migrated away.
- Added View > View Options (Cmd-J), explicit folder/subtree/default application and
  capability-disabled controls. The sheet owns its originating URL across asynchronous work.
- Added real Date Added, Tags, iCloud Status, Shared By, Last Modified By and Version values.
  Sharing uses the iCloud owner/most-recent-editor resource keys, not filesystem ownership;
  version uses Spotlight's kMDItemVersion. Blanks explicitly mean absent provider metadata.
  Metadata reads are lazy, generation-guarded and cache-bounded, not a whole-folder walk.
- Ordinary eligible Rename now offers an explicit-accept suggestion, and the torrent Save
  panel uses the same acceptance rule. On-device model readiness gates automatic presentation;
  no model means ordinary inline rename. Suggestions retain the output extension and cannot
  overwrite typing or deliver after cancellation. Other apps' Save dialogs are outside Pathem.
- Extension changes use a Cancel-first warning before the real rename. The sheet captures the
  original local folder. Both manual AI Rename and ordinary Rename share this path.
- 30-day cleanup is OFF by default. While Pathem is running, the shared daily worker processes
  the home Trash only; unknown date-added values, symlinks and changed identities are retained.
  Opt-out cancels between deletions. External-volume Trash and execution while Pathem is closed
  are not implemented; do not describe this as a system-wide Finder policy.

Retained sample records (local `/tmp/pathem-finder-*` logs):

- `focused.log`: initial build and seven focused tests PASS.
- `focused2.log`: FAIL: missing PathemEngine import in the Save adapter. The import correction
  was made before that compiler had fully closed, also producing an input-modified error.
  Subsequent build inputs were frozen through actual terminal; do not count this run as green.
- `focused3.log`: corrected build and seven focused tests PASS.
- `native1.log`: configuration guard correctly REFUSED a `/tmp` root outside the system's
  canonical temporary directory. Retried using `mktemp -d` under the actual temp directory.
- `native2.log`: 193/194. Relative date text, native controls, suggestion cancellation and
  extension Cancel/Confirm PASS; inherited-column reset FAIL.
- `focused4.log`: eight tests PASS, including an actual filesystem move proving date-added is
  fresh while content modification time remains old. No owner Trash was touched.
- `native3.log`: 196/197. Grid geometry and visible-window metadata PASS; same column-reset
  assertion still FAIL. Disabling AppKit autosave for automation did NOT fix this failure:
  the autosave attribution was refuted. Isolation remains valuable independently because
  tests must not read/write owner column defaults.
- Convicted cause: `explicitColumns ?? lazyInheritedColumns` never initialized the fallback
  on the first explicit override; Reset then captured that override as its inherited layout.
  Eagerly snapshot the fallback before any mutation. The original reset assertion is unchanged.

Live iCloud sharing/provider metadata, real model output, external receiver integration and
an installed owner window remain environmental boundaries, not passes inferred from fixtures.

## Follow-up safety finding: shared remote scratch cleanup

Evidence: `BrowserViewController.viewDidLoad` calls `cleanupRemoteTemp` for every browser window.
That method recursively removes the fixed `Pathem-Remote` and `Pathem-Archives` directories,
despite its comment saying it runs once. A second window or a test process can therefore remove
another window/process's opened remote files or mounted archive working copies. This is a direct
source-confirmed delete path; no destructive reproduction against shared/owner roots is allowed.

The first full gate was deliberately terminated at its own verified make PID before E2E launches
after this finding. It had passed the fresh warning inventory (15 known, 0 new), but is NOT a
full green gate. The earlier native launches predate this discovery; no owner-file loss has been
established, and lack of a failure report is not proof of no effect.

Fix design: each process owns a UUID session scratch namespace. Browser creation prepares
directories idempotently and never sweeps previous or legacy namespaces. Automated launches
place that namespace under their guarded, isolated configuration root. Prior editable remote
files are retained rather than guessed disposable; a future explicit recovery/cleanup UI can
manage them with user intent.

Sample criteria before running: two distinct sessions must have distinct paths; preparing a
second session and preparing the first twice must preserve an existing sentinel's bytes. A real
second browser window must preserve a sentinel in its first window's session. Tests must use
only disposable roots and must not read or delete the legacy shared directories.

Safety sample: `focused6.log` PASS 9/9, including distinct session paths and repeated preparation
preserving both remote and archive sentinels. `native5.log` PASS 199/199, including a real second
BrowserViewController view load preserving the first browser's remote working-copy bytes. The
old destructive path was not replayed against any shared directory.

## Further audit findings (Mission 58; remaining validation and fixes)

1. **P1, download destination reservation.** In `downloadSelectedRemote`, all queue items are
   built before any download starts. `safeLocalName` maps both `report.txt` and a legal Unix
   filename containing a backslash before `report.txt` to `report.txt`. `uniqueLocalURL` only
   checks the current disk, so both queued items can choose the same absent destination.
   Curl downloads use `-o` and SFTP uses `get`; neither queue reserves the first choice. Proven
   by source/path construction; actual receiver overwrite still needs an isolated provider test.
   Design direction: reserve normalized destination keys across the batch and create safely;
   keep a distinct same-name/Unicode/case-insensitive-volume control.
2. **P1, remote Rename origin ownership.** Originally the sheet chose operation kind and read
   `pane.remoteContext` at acceptance, permitting changed path/server and local↔remote mode
   crossings. This batch captures the origin before presenting and rejects changed kind,
   connection, path or credentials before dispatch. Discriminatory predicates pass; real
   delayed-sheet/provider acceptance remains untested. A reconnect to identical context is
   not separately invalidated by a session generation. Retain that validation in Mission58.
3. **P2, stale archive mount completion.** `browseArchive` awaits extraction, then unconditionally
   calls `pane.mountArchive`; that method changes navigation and focus. There is no origin or
   generation check between extraction completion and mount, so navigation away can be undone
   by a late completion. Source-confirmed missing ownership guard; native delayed-extractor
   reproduction remains pending. An unchanged-origin completion must continue to mount.

These findings do not close older Mission 53 tasks 44–46 or environmental release gates. The
batch's fixes do not establish that an arbitrary live location/scroll change has this cause.

## Full-gate negative results and next controls

CI2 completed all 811 unit tests and the warning inventory (15 known, 0 new), but product E2E
was 64 PASS / 1 standing transparent-capture SKIP / 3 FAIL. Packaged release was not reached.
Failures: live Organize AI reports ModelManagerError 1026 despite available status; create/rename
blocks extensionless-file -> `.txt`; native UI was 43/49, including real-dispatch zoom failures.
The focused 201-check sidebar suite and search465/Finder198/background263/layout161 checks pass.
Do not waive any of these failures or turn an AI error into a successful/skip result.

Controls written before running: repeat UI49 alone to retain every failure, without changing
assertions. Separately build a tiny FoundationModels-only program, importing no Pathem code,
and send one synthetic plain-text request. If it also fails with 1026, that establishes an
independent framework/service failure, not its exact cause; if it succeeds, investigate Pathem's
structured-generation path. No system update, service restart or Apple Intelligence toggle is
authorized by this diagnostic. The existing OrganizeAI.swift source is unchanged in this batch.

Control outcome: `/tmp/pathem-model-control.swift` imports only Foundation/FoundationModels.
Build PASS; execution exit2, availability `available`, then the same underlying
ModelManagerServices.ModelManagerError1026. Thus the live generation failure also occurs outside
Pathem; its exact system/service cause remains unknown. Host inspection: macOS27.0.1,
Xcode27.1, selected SDK27.0. Apple staff discuss SDK/OS matching as a possible cause in
<https://developer.apple.com/forums/thread/842733>; that is a hypothesis, not a diagnosis here.
No settings, services or OS/toolchain installations were changed.

UI-only repeat retained the same six failures (43/49). The next treatment improved to46/49:
unchanged-folder delivery is now cached; metadata does no redraw when no extended columns are
visible, and metadata redraws defer during inline edit and preserve native selection/viewport.
Appearance restoration retains a legal negative table-header inset while preserving zero as the
upper clamp when a document shrinks (the previously measured contradictory controls).

The three remaining failures were New File inline naming and real-dispatch zoom. Instrumentation
showed a pending sheet, zero received key events, and unchanged scale. Convicted cause: New File's
post-listing callback calls ordinary Rename, which now offered the automatic AI sheet for an empty
file. Its existing inline-name contract was lost, and the modal sheet consumed later shortcuts.
New File now explicitly requests ordinary inline naming (and checks its originating pane is still
active). Subsequent ordinary Rename still offers suggestions. No zoom key-routing fix was guessed.

`focused8.log`: nine focused tests PASS. `ui49-treatment2.log`: original49/49 PASS, including
real dispatch receipts (no sheet; keys0->2, scale1.15->1.30->1.15) and negative-inset refresh.
`native7.log`:201/201 PASS. Adding the first filename extension is now allowed without a warning;
replacing/removing an existing extension still has Cancel/Confirm controls. Full CI3 adds native
late-Apply origin ownership and nested-symlink/replaced-entry Trash controls before final acceptance.

## Parallel review controls (written before execution)

Three independent read-only reviewers found four view-ownership/default bugs, list icon glyph
upscaling, stale-window retention re-enablement, and a suggestion preview cloud/cancellation gap.
The treatment must preserve drilled Column location/selection and child rules while saving the
pane-root format; both default commands must leave global Settings authoritative. Nested subtree
rules must be replaced but sibling/root rules retained. A small-image/large-box control must
distinguish glyph enlargement from an enlarged box. Open Settings must preserve newly applied
font/date defaults on an unrelated edit. Two windows must remain retention-OFF after a stale
snapshot, and no timer/worker may start during automation. Text preview must read an ordinary
fixture but reject symlinks, nonregular modes, and dataless flags. A suspended preview canceled
before completion must invoke no model; the uncanceled control must invoke exactly once and
still require explicit Use. Any failure is a failed sample, not a waiver.

CI3's retained log establishes 811 unit passes and the original UI49/sidebar204 passes, but ends
during conflict capture with no retained final summary/terminal status. Its process no longer
exists. Treat this run as incomplete, not a claimed 66/1/1 result. The independent AI1026 failure
remains recorded; packaged verification is still required after review treatments.

Review sample: updated unit suite PASS (15 XCTest +797 Swift Testing). Native236 sample was
232/236; isolated repeat54/58 retained the same four failures. Column receipts prove the root
font18 and child sentinel11 were saved correctly, but refresh returned the active location to
the root, replaced the key table, selected the child folder instead of its file, and moved the
horizontal origin463->182. Mechanism: restoring root/drilled selection during reload invoked
the normal selection delegate, which treated it as a fresh drill. Treatment suppresses those
gesture callbacks while restoring selection, as the existing sort/style paths already do.

The first icon instrument was INVALID: NSCell.imageRect reported the whole48/64 box for both
UpOrDown and Down controls, so it could not discriminate scaling. No product regression was
inferred from that instrument. Replace it with actual drawing of a synthetic16pt red image
into an RGBA bitmap, requiring positive Down-control pixels and >2x red pixels in treatment.
Production icon constraints are asserted separately before any test frame assignment.

New Group/Sort source audit (screenshots not yet attached): smart-result header sorting returns
through smart reload without reordering; smart/remote grouping does not deliver grouping and
persists onto the local fallback folder; expanded Tree children retain fixed name ordering.
These preexisting paths are queued in Mission58, not claimed fixed by the view-options batch.

Treatment sample PASS58/58. Column receipts: root18/child11 retained, child file selected,
same key table, one completed listing, horizontal origin463->463. The interim root-ownership
assertion compared equivalent directory URLs with different trailing-slash spelling; checking
their canonical path corrected that test, not the product. Direct NSImageView.draw produced
zero pixels in both controls (another invalid instrument); drawing its real image cell through
the bitmap context discriminated:48pt=2304 red pixels,64pt=4096, Down=256 in both. Constraints48/64
also pass. No full-window visual-fidelity claim follows from this targeted raster control.

Stale-retention native controls pass across two real Settings instances, replayed stale full
snapshot, unrelated checkbox edit, saved preferences OFF, and refused stale reseed; automation
starts no cleanup worker/timer. Preview regular/symlink/mode/flag controls and canceled/uncanceled
delayed-preview generator counts pass. Rename context predicates pass unchanged local/remote
and changed mode/path/server/credentials; this is predicate/source-wiring coverage, not a
delayed real remote-provider acceptance test. Those broader Mission58 controls remain open.

Normal commit-hook Swift tests and local packaging now cap workers at2; no tests were removed,
weakened, skipped or waived to impose that resource cap. No installed app, OS setting, owner
Trash, updater, signing credential or public distribution changed.

## Next audit units (design only; no claimed treatment)

Download collision is coupled to `TransferQueueController.retry`: it unconditionally removes
`progressFile` before reusing the old closure/path. Source inspection confirms providers write
directly to that destination. Reservation alone is insufficient. Plan batch-distinct normalized
names, fresh per-attempt owned staging on the destination volume, and no-replace publication
(macOS renameatx_np/RENAME_EXCL, failing closed if unsupported). Retry must never delete a public
destination or reuse an earlier attempt's ownership. Reproduce via an injected writing provider
through the real queue, using distinct payloads and colliding sanitized names. Controls must
retain preexisting files, dangling-symlink outside targets, destinations created after enqueue,
and replacements before Retry; cover Unicode/case policies and cancellation before start.
No live provider overwrite has been exercised, and this batch does not fix those queue paths.

Archive completion needs per-pane request UUID plus terminal teardown state, not path equality
alone: navigation away/back, smart/remote replacement, overlapping extraction, Column effective
directory changes and close must invalidate ownership. Watcher/style refresh must not. Guard at
the final mount mutation boundary; stale errors must not present alerts or take focus. Each
attempt needs its own session-owned scratch child; remove only an unmounted exact attempt after
its extractor has actually terminated. A continuation-gated extractor should distinguish normal
mount/failure, navigation away/back, both completion orders of overlapping requests, teardown,
and stale failure, while asserting untouched sibling/mounted sentinels and actual handler terminal.

Group/header-Sort should share the working sort delivery path: smart results reorder/rebucket
held entries without fallback-folder writes; remote grouping rebuckets current content without
network re-listing; local changes still persist. Test actual rows/headers/sections using values
whose size order contradicts name order, plus a remembered-format write spy and unsupported-mode
controls. Tree needs delivered sort policy for both loaded and newly expanded children while
retaining node identity/expanded paths/selection/viewport; avoid whole-subtree reload on unchanged
watcher refresh. Screenshots are still needed for exact Finder option-list comparison.

CI4 ACTUAL terminal: make exit2; unit812 PASS, warning inventory15known/0new, product E2E
64PASS/1standing-captureSKIP/3FAIL. OriginalUI49, sidebar236, search465, Finder198,
background263, Settings588 and other product checks pass. Failures: independent AI1026,
content201/204 and gallery54/57. Isolated background-tab sample28/31 names the exact three:
displayed/hidden/watcher Column refresh activation receipts are absent. Every active-tab,
selection, displayed-window, actual watcher listing and explicit focus/close invariant passes.
These assertions required the unwanted restoration-generated callbacks now intentionally
suppressed; they are obsolete instrumentation, not evidence of a tab-ownership regression.

Revised control criteria before execution: passive displayed/hidden/watcher Column refresh
must emit NO activation callbacks and must preserve all existing ownership invariants. Exercise
the TabStrip ownership gate separately through its production captured-source callback: a
displayed source must activate from the other side (positive control), while a hidden source
must reach the gate with a recorded receipt but cannot replace the foreground tab (negative
control). Keep all previous listing/selection/window/focus/close assertions. This retains a
discriminatory gate test without requiring the fixed refresh bug to recur.

Revised isolated sample PASS33/33; visible positive and hidden delivered-but-rejected controls
both pass, alongside all previous behavior invariants. Incremental compile warning gate:0new.
Full affected content/gallery suites and the normal packaged target are the next acceptance
checks. No production code changed after CI4; this treatment changes only its obsolete test
instrument and adds the two explicit gate controls.

Full affected retests ACTUAL natural exit0: content206/206, gallery59/59. All previous
behavior assertions remain and the two additional explicit activation controls pass. The last
full make-ci invocation remains recorded64/1/3 (not rewritten as green); affected suite retests
resolve its two test-instrument failures. Independent live AI1026 remains unresolved.

Packaged target ACTUAL natural exit0:14PASS/0SKIP/0FAIL, ARM64 ad-hoc bundle with helper and
six-language completeness, strict signature, hardened runtime, update metadata, config-root
guards, actual launch/visible window, scratch config persistence and updater-disabled receipt.
Release compiler inventory:12known/0new. This is local bundle verification, not universal,
Developer-ID/notarized distribution, installation or publication. Mission57's full-validation
task remains pending because live AI1026 is unresolved; no full-CI-green claim is made.

## Mission59: screenshot-matched sorting and grouping

Trigger: owner supplied the actual Finder Sort By and Group By menus and requested fixes.
The Sort screenshot has8 choices (an earlier chat count of9 was wrong), Group has10 including
None. Source confirms sort lacked Kind/DateAdded/Tags; group lacked Name/Application/LastOpened/
DateAdded/DateCreated. Toolbar offered only3 sorts. Existing smart header-sort/group delivery
could persist a local fallback format or never visibly apply. Expanded Tree children used
fixed name order. Date Last Opened displayed POSIX access time, not Spotlight last-used time.

Criteria written before new controls run: every native picker/menu must expose all8/10 in
screenshot order; old raw config and command IDs must retain meaning. Real List headers must
select the new sort keys. Pure ordering must distinguish values that contradict filename order,
both directions and stable name ties/folders-first. Group headers must reflect independent
lastOpened/added/created dates, named (including colorless) tags and resolved application names;
unavailable data stays explicitly unknown. Current Name grouping is initial-based; no claim
of exact Finder's name bucket ranges or multi-tag duplication semantics follows from a menu.

Metadata is selected-key-only, off-main and never read in comparator/drawing/group bucketing.
The normal name/size/modified/created path must request none. Remote/synthetic entries cannot
probe same-named files in a retained local directory. Smart group/sort must change actual rows/
headers with zero saved-folder writes; contrasting local actions must persist. A suspended
metadata request must visibly enter, then navigation/new sort/teardown must reject its late
delivery. Column and Tree tests must check existing/new child sorting and actual completion,
not just root order or a menu checkmark, preserving identity/selection/scroll. UI tests use
injected metadata/provider boundaries and disposable files; no owner file contents or services
may be modified. Real metadata fixtures separately establish type/tags/date-added delivery;
Spotlight absence is a known-unknown control, never fabricated filesystem access time.

Preexisting AI1026 and visual/environmental release limits remain open; this work does not
waive them or authorize installation/restart/publication.

Integration review convicted additional boundaries before native validation: unconditional
post-metadata sorting displaced explicit ranked-search order; a sort change while a remote
provider's first metadata request was held could discard the only raw listing; a partial
Kind snapshot hid correctly loaded Tags cells; absolute device paths could reach host-only
lazy metadata readers. The treatment preserves search input order, retains provider values
before enrichment, prefers independently gathered visible tags, and delivers an explicit local
metadata capability to the actual content. Remote previews and package-icon path lookup are
also denied rather than treating `/device/path` as a host path. Tree's independent child
delivery now waits event-driven for inline editing to end and revalidates ownership; view swap
and teardown cancel its workers. Deterministic gate controls hold actual worker completions
before sort/navigation/collapse/edit/close, rather than relying on timing luck.

First local compile ACTUAL exit2: test fixture used the SDK's new macOS26-only writable
tagNames property despite Pathem's lower deployment target; the Column completion adapter
also needed an explicit MainActor/Sendable annotation. Replaced the fixture setter with the
existing FileMetadata API and annotated the callback; this failed run is not a test pass.
Second compile ACTUAL exit2: a new remote-path control attempted to mutate immutable
FileEntry.location. FileEntry(contentsOf:) already records the actual parent; removed that
redundant test assignment. No production compiler errors remained in this run.

Third build/unit gate ACTUAL exit0:15 XCTest and807 Swift Testing tests pass (822 total).
Focused native1 ACTUAL exit1:186/190. All menu/ordering/smart/remote/Column controls passed;
Tags rendering and three dependent Tree editor/resort/collapse checks failed. The Tree
instrument could gate an earlier valid worker that became canceled before the current worker
arrived. Treatment: record worker generation and require the current generation to be held
before starting the editor. A separate disposable Foundation control refuted the hypothesis
that combined iCloud URL resource keys prevent named-tag reads: single and combined key sets
both returned the actual named tag. Keep the remaining Tags failure open until instrumented.

Fourth build/unit ACTUAL exit0 (822 tests). Focused native2 ACTUAL exit0:191/191,
including current-generation Tree editing/collapse/teardown controls. A diagnostic nevertheless
showed direct named tags present while a cold FileColumns.gather returned nil. The first
Foundation control above had primed the URL with a tag-only read, so it did not test the cold
condition and its broad refutation was invalid. A corrected20-file control requested the
combined Finder+iCloud key set FIRST:20/20 returned missing tags; subsequent independent
tag-only reads returned all20 correctly. Split the ordinary dateAdded/tagNames request from
provider-specific iCloud keys, preserving optional-field unknowns; add a cold first-read unit
test plus contrasting untagged fixture and retain the native actual-cell check. This fixes a
measured SDK interaction rather than relying on whichever background reader won the race.

Additional ownership invalidations: remote entry invalidates outstanding smart-content tokens;
teardown invalidates outer enumeration generations as well as metadata and child workers.
Local navigation explicitly leaves remote context, clearing delivered remote rows before
re-enabling host readers. No provider path is interpreted as a host path during that transition.

Fifth local build/unit gate ACTUAL exit0:15 XCTest +808 Swift Testing (823 total), including
cold first-read tagged fixtures and untagged contrast. Final focused native3 ACTUAL exit0:
192/192. It covers every screenshot choice, native menus/pickers/header sorting, group
renderers, opposed metadata values in both directions, smart0writes versus local persistence,
remote1provider-list despite sort changes while hydration is held, old-result rejection,
Column child order/location/selection/scroll, and current-generation Tree child order/editor/
collapse/close. Native1 remains the recorded186/190 failed instrument run, not silently erased.

Broad CI1 ACTUAL exit2:823 unit tests pass; clean warning inventory15known/0new; all six
localizations pass. Debug E2E summary64PASS/1standing-captureSKIP/3FAIL: search449/465,
Finder196/198, sidebar425/428. Background menus308/308, content206/206, gallery59/59,
settings-defaults918/918, opener51/51, layout161/161 and transient53/53 passed. Root's new
ordinary-navigation pending-action clear introduced a regression: reveal queued its explicit
selection BEFORE navigate, which then canceled it. The source-convicted correction navigates
first and arms that destination-owned selection synchronously afterward, before the MainActor
can deliver its async listing; ordinary navigation still cancels stale actions. Added an
explicit Reveal positive control; existing search matrix covers the contrasting navigate-away
case. Affected suites must be rerun with full logs; do not count the old CI as green.

Post-correction build/unit ACTUAL exit0:823 tests. Full affected native retests ACTUAL
natural exit0 each: Finder198/198, search465/465, sidebar/transfers429/429 (including the
new explicit Reveal control and all193 focused sort/group checks). The unchanged search
navigate-away negative control passes, so the correction restores explicit Reveal without
allowing old queued actions to cross directories. These retests resolve CI1's three failed
scenarios; the last complete CI invocation itself remains the recorded64/1/3, not rewritten
as a green run. Prior independent live AI1026 was not re-probed or waived by this batch.

Local packaged target ACTUAL exit0:14PASS/0SKIP/0FAIL; ARM64 ad-hoc bundle, six languages,
helper completeness, strict signature, hardened runtime, scratch-only configuration, visible
launch and updater-disabled receipt. Release warning inventory12known/0new. No installation,
owner-process restart, Developer-ID/notarized distribution or publication occurred.

Final source audit also records an unchanged limitation for Mission58: reused loaded Tree
children retain enumerated size/mtime when only file contents change and parent-directory
mtime does not. This batch refreshes selected extra metadata, not those stored stat fields;
a targeted content-only-edit fixture and invalidation design remain pending, not claimed fixed.

## Owner-requested installation

After the source-only handoff, the owner explicitly requested installation. Rebuilt frozen
8c32a39 in an isolated install workbench, ARM64/jobs2, using the existing Developer ID signing
identity without notarization or publication. Packaged verification ACTUAL exit0:14/14;
strict deep signature, hardened runtime, resources/helpers and isolated visible launch pass.

The stock install branch uses broad app/helper pkill, so it was not invoked. Staged the verified
bundle on the Applications volume and confirmed it satisfies the previous app's designated
requirement. A first requirement check omitted codesign's literal-source '=' prefix and failed
before changing the installed app; corrected against the local manual and verified successfully.
Real renamex_np controls proved missing-source rejection, atomic exchange and rollback on
disposable directories before exchanging the two app bundles. The old notarized bundle remains
at /Applications/.Pathem-install.9Ccsxc/PreviousPathem.app and still passes strict signature checks.

Post-install signature and full byte/symlink comparison pass. BSD diff initially warned about
framework symlink loops; its documented --no-dereference comparison then passed without warnings.
Installed main-binary SHA256 e7dad414b7ad2165c948101432c77a99e8d6d9221ce3bb8326589fd95242df96.
Running app PID45412 and its original birth time remain unchanged; no app/helper was signaled,
quit or relaunched. The installed update takes effect on the next relaunch. This is a locally
signed installation, not a new notarized distribution or a public release.

## Rename and related dialog layout audit

Trigger: owner screenshot shows Rename's field and suggestion controls overlapping the prompt
and clipped at the sheet's right edge. The owner requested a fix and an audit of similar issues.
Source candidate: a zero-frame NSStackView is installed as NSAlert.accessoryView with width
constraints but no measured frame. Existing tests cover standalone suggestion behavior, not
the complete alert. This is a hypothesis until native frame measurements reproduce it.

Criteria before native probes: ordinary field-only Rename must be the good control; the current
suggestion-stack construction must be capable of failing containment/overlap checks. Record
accessory frame/fittingSize and full sheet bounds, actual field/label/button alignment rects.
The fix must keep all visible controls inside the accessory and complete sheet, below message/
prompt and above action buttons, with no unintended overlap. Exercise long generic filenames,
late suggestion/error text, suggestions absent, light/dark appearance and translated labels.
Present/cancel actual sheets on disposable windows; no owner files or live model requests.
Audit other NSAlert/NSSavePanel accessories using the same construction and reproduce candidates
before changing them. Known-good manually framed accessories must not regress. A geometrically
rejected render is not a visual pass; any failed run stays recorded. No installation/restart
or change to the Rename operation/confirmation semantics is implied by this work.

Native baseline ACTUAL exit0 reproduced the screenshot: the current constrained stack had
frame0x0 and fittingSize380x78; NSAlert reserved a260x138 content area, placing the380-point
field at x130 (outside the sheet). The ordinary framed-field control was contained in412x162.
Measuring the identical stack before attachment produced412x216 and contained all controls.
The instrument therefore discriminates the broken and good constructions, rather than just
checking expected values. A frame-owned measured accessory is the selected correction;
asynchronous suggestion changes must remeasure the parent and alert too.

Audit of37 accessory assignments found the same zero-frame construction in Commander F-key
settings and torrent-save suggestions. A separate Connections path-row contradiction fixes
each field at250 points inside a230-point horizontal row, before its Choose button/spacing;
this cannot satisfy containment. Other fixed-height/localized forms remain risks until tested,
not proven bugs. Failed suggestion delivery also previously left an earlier successful
suggestion enabled; clearing both its value and Use state prevents stale application.

Implemented measured frame-owned accessories for Rename, its filename suggestion controller
(also the torrent Save panel), and Commander settings. Inner content retains Auto Layout;
dynamic suggestion height propagates to the parent and NSAlert.layout without touching the
field. Connections fields now flex within230-point rows while preserving usable field and
Choose-button widths. Rename/provider/confirmation behavior and save/cancel persistence are
unchanged. Production-used factories let checks inspect the actual surfaces, not a replica.

Validation: cold jobs2 build/test ACTUAL exit0,15 XCTest+808 Swift Testing cases. Six-language
catalog lint passes. Warning inventory reports one newly inventoried diagnostic in unchanged
LinkOperationsTests.swift ('stale' can be let); this audit introduces no production diagnostic,
and the inventory run itself is recorded as FAIL rather than waived/full-CI-green.

Focused native sample ACTUAL final exit0:207/207 checks, including positive and deliberately
clipped/overlapping negative geometry controls; actual Rename sheets with suggestions on/off,
300…520-point fields, late wrapped success/error, typing/caret/focus preservation, stale-delivery
rejection, two appearances, English/German/Japanese-sized chrome; real Commander long popups,
six-language230-point path rows, and cancel-only NSSavePanels. Initial sample201/207 and followups
203/207,205/207 remain failed runs: receipts convicted duplicated popup/button child title fields
in the overlap instrument and NSSavePanel's separate NSAccessoryViewWindow identity, not control
clipping. The instrument now counts distinct controls and requires actual sheet/accessory visibility.
An initial /tmp config-root launch was correctly refused64; the sample uses the platform temporary
root. Cached PNG lacked native chrome and was rejected, not counted as screenshot verification;
the complete native geometry/interaction checks are the UI evidence. No live AI requests occurred.

Remaining hypotheses are explicitly queued in Mission58: Connections warning/root height,
Templates/External Commands hints, speed-limit forms, remote Keychain checkbox and color-rule
style-row localization. These were identified by source audit, not claimed reproduced or fixed.

Broader native regressions ACTUAL natural exit0: full sidebar/transfer/view-options/sort-group
suite636/636 (including207 dialog checks) and transient controls/cancellation53/53. Final
incremental app build passes with0 owned warnings. Full CI and package/install were not run for
this source-only patch. Owner app PID56392/birth time remains unchanged; no owner process signals.
