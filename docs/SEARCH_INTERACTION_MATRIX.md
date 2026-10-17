# Mission 53.13: remaining search interaction matrix

Trigger: the owner requested continuing Mission 53 after the file-safety batch.
The existing 170 search checks prove literal mode/scope semantics and native picker
ownership/cancellation, but the underlying-pane viewport check uses three List
rows at scroll zero. Pane-switch Reveal is also checked only in List. There is no
real multi-row result-table Return/keypad Enter activation contrast.

## Criteria before the sample

Use disposable left/right folders, each with 160 identically named text files but
different root paths. Use the production filename backend, toolbar/registered
Cmd-F entry points, actual search-field editor, and the actual result table.
No default application is opened. No user folder is approved in a picker.

- Prove the requested content view was delivered and all 160 entries arrived.
  Select the last item in both panes and require a genuinely nonzero viewport and
  visible selection in each key view's own clip (Column has an inner table clip;
  Gallery scrolls horizontally). A zero offset is an invalid preservation input.
- Present search from the origin. Type a matching query through its field editor,
  then activate the other pane before the debounced request completes. Require a
  completed-request receipt and 160 results belonging only to the original root.
  Both panes' directory, selection, view identity and scroll offsets must remain.
- Differing controls: a nonexistent query returns zero; clearing returns idle with
  disabled actions; dismissal/reopen does not revive an old query. The same pane
  invariants must hold across each transition, not only final state.
- Reopen from the origin, query again, scroll the real result table to a selected
  nonfirst row, move Down/Up through the installed field delegate, and activate the
  selected row using Return or keypad Enter delivered to the actual table's
  `keyDown`. Reveal must dismiss search, select/show that exact item in the
  originating pane, and not navigate, select, scroll or activate the other pane.
  Missing field editor, wrong result root/count, zero viewport, absent event or
  response receipt invalidates the instrument instead of passing a timeout.
- Small sample: List/left/toolbar/Return and Gallery/right/Cmd-F/keypad Enter.
  Only after the design discriminates with actual delivery, expand to every view
  on both sides (10 cells). Include origin-directory/reopen/delayed-query races
  with explicit old/new backend receipts, not a fixed wait as evidence.
- Search automation must require an isolated temporary config root before browser
  startup, like the existing configuration test modes. Add safe missing/non-temp
  refusal checks only after installing this guard; do not run an unsafe old-source
  missing-root probe that could touch owner configuration.

Synthetic key events exercise the real table responder method, not physical
keyboard/global-monitor dispatch. Existing picker/Spotlight/default-app/native
appearance limitations remain environmental or in other Mission 53 tasks.
No automatic golden-image approval, install, publication, TCC, history or credential
change is included. Fix production behavior only if the baseline convicts it.

## Verdicts

Baseline build passes (fresh warning inventory: 15 known, zero new). The two-cell
native sample is red **50/53**. All view/root/field-editor/backend receipts,
nonzero viewport inputs, no-match/clear/reopen controls, selected result row,
Down/Up movement, and unaffected-other-pane controls pass. Two mechanisms emerge:
keypad Enter does not dismiss/Reveal while the Return contrast dismisses; Return
selects the exact correct origin filename but it remains offscreen. Record raw
clip/selection geometry before choosing a Reveal fix. No production behavior has
been changed for either failure at this point.

The new search-mode config guard passes both missing and non-temporary refusal
controls (2/2). An unsafe old missing-root probe was deliberately not executed.
Repeated baseline with raw geometry is again 50/53: List selects match-090.txt,
but its clip origin is (0,-28), visible height 678 and selection rectangle nil.
Source confirms `reveal` queues only `selectNames`, which intentionally does not
scroll, after navigation has reset to the top. This is a product failure, not
the nonzero viewport instrument. Keypad Enter still fails both activation checks;
Return's dismissal and every unaffected-other-pane control still pass.

Treatment is limited to accepting keyCode 76 alongside 36 in the result table,
and giving explicit Reveal a directory-owned post-listing `select(name:)` callback.
Generic selection restoration remains non-scrolling; the existing directory
ownership guard also owns this callback. No speculative layout/global-selection
or native-key-monitor changes. Small treatment and expanded verification pending.

Treatment sample passes **53/53**: List's selected result now has a real visible
rectangle and clip y=1511; keypad Enter reveals Gallery's exact result and closes
the panel. All formerly red checks and preservation/negative controls pass.

Before full expansion, add controlled races to the bounded sample: hold an old
request after its backend starts; navigate its origin; dismiss/reopen from the
other root; start/deliver the new request, then explicitly deliver the cancelled
old response. Both completions must reach the controller. New scope/query/results
and the actual Open button's nonfirst URL must remain owned by the new session;
callbacks record URLs only. Also arm explicit Reveal then immediately navigate to
a one-row directory containing the same filename. Require that new one-row listing
to arrive and remain unselected. No elapsed-time-only or identical-listing receipt
can satisfy this control. Further sample and ten-cell/full-suite verdicts pending.

The strengthened sample passes **66/66**. Both old/new backends start with their
respective root receipts; new then cancelled-old responses explicitly return to
the controller. New scope/query/results and second-row Open callback remain
correct; no external application is launched. The separate one-row navigation
target arrives and remains unselected despite containing the same filename.
Fresh baseline/treatment/build warning union remains 15 known / zero new.
This validates the instrument before expanding to the full ten-cell matrix and
ordinary search regression suite.

First full expansion is red **417/443**. The repeated same-mode setup invalidates
its preservation inputs: `navigate` requests a fresh reset, but 160 existing rows
can satisfy the old predicate before that new listing arrives. Add DEBUG-only
accepted-listing completion counters and require new completions plus realized
rows before snapshotting. Do not change production retention for those failures.
Both Column cells additionally switch the active side during explicit Reveal;
recheck in a bounded two-Column-cell sample after fixing delivery instrumentation,
before convicting or changing Column activation.
The instrument also requires the main window's actual first responder to be the
other pane's key view, not merely a changed active-side variable. Column's native
explicit-focus control must still activate its pane; suppressing all activation
would be an invalid repair. A first patch attempt used stale formatter context
and was rejected without changing files; corrected before rebuilding.

With actual accepted-listing and first-responder receipts, bounded Column baseline
is **70/72**. All preservation/input/race controls pass; only the two post-Reveal
active-side invariants fail. Explicit native focus still activates Column correctly.
Before a Column repair, temporarily restore the original names-only Reveal path
to distinguish a pre-existing activation issue from a regression in the new explicit
scroll callback. This counterfactual is not final code or a waived failure.

Original names-only Reveal counterfactual is **68/72**: both active-side failures
remain, plus both offscreen results return. This proves activation was not caused
by the new scroll callback. The original explicit scroll repair is restored.
Column's selection delegate unconditionally emits user activation even when
called by the programmatic `select`/`selectNames` API. Scope an activation-only
guard around those APIs; keep selection notifications, drill/preview updates and
real first-responder activation intact. This does not change tab ownership or
claim to explain Task 39's original first-launch intermittent.

Corrected Column treatment is **72/72 PASS**; List/Gallery sample with the same
accepted-listing and actual-other-first-responder instrument is **70/70 PASS**.
Programmatic Reveal retains the other active side, while explicit Column focus
still activates normally. Every new completion/focus input receipt passes.
Expand only this corrected design to the full ordinary search suite/ten cells.

Corrected full ordinary search suite passes **465/465** (previously 170). Every
view on both sides has new accepted-listing receipts and real nonzero viewport
inputs. All original mode/scope/native-picker regressions and new keyboard,
visibility, pane ownership, negative query, clear/dismiss/reopen, controlled old/new
response, actual Open callback and wrong-directory Reveal controls pass. No
timeout was widened and no failed assertion was removed.

## Final local gates

Full `make ci` exits 0 on the final source. Fresh debug/release warning inventories
are respectively 15/12 known owned warnings, zero new and zero unparsed. All
15 XCTest and 786 Swift Testing tests pass. Product E2E reports 67 passed,
one standing browser-image skip and zero failed; search is 465/465 and mandatory
configuration-root refusal controls are 12/12. The browser cached image is still
rejected as mostly transparent, not accepted as native visual evidence. Existing
popover, content-preferences and disk-image scenarios pass this run, but this does
not establish the cause or resolution of intermittent Tasks 36, 39 or 42.

The current-host arm64 ad-hoc package passes 14/14, including bundle/signature,
hardened runtime, six language resources, configuration-root refusals and an actual
visible-window launch with scratch configuration and updater disabled. This is not
universal, Developer ID/notarized, native visual or owner-environment sign-off.
No owner application was installed/restarted and nothing was published.

CI output and fresh compiler logs were retained outside the temporary workbench as
`/tmp/pathem-search-matrix-ci.log`, `...-ci-debug-build.log` and
`...-ci-release-build.log`; bounded sample/counterfactual logs share that prefix.

This closes the finite continuation tracked as 53.43 through the normal gates;
the broader 53.13 remains open for its native visual/default-app/environmental
acceptance boundaries. No screenshot baseline or physical-keyboard claim is added.
