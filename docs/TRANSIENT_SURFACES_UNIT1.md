# Transient surfaces Unit 1 review receipt

Status: READY for review, not approval to land. Unit 2 and visual-baseline work have not started. The clean product run is red; no known-findings waiver is applied.

## Scope and evidence

- Source inventory: 196 rows and 196 builders, A116/B47/C29 plus four unclassed wrappers. Thirty-eight implicit menus have source-pinned attachments and remain outside native structural coverage. Four reusable dynamic context-menu sites retain unresolved builder provenance and conservative A classification. There are zero unclassified sites.
- Explicit exclusions: 32 harness/debug files, 53 constructor/presentation expressions. The independently reviewed CleanupController count remains four physical presentations and four builders, plus its separately classified wrapper caller.
- Native sample: exactly Rename, Reclaim Delete Now, and conflict popover. German/Japanese, light/dark, 720x420/1100x700, and short/255-character Rename names produce 32 A variant cells and 96 presentations over three cycles.
- Plain alerts: ten real localized constructions, all six shipped languages, both sizes, 120 structural cells. Extension confirmation, demo offer, and folder-handler confirmation additionally exercise three cancel/reopen cycles at both sizes in German, 18 presentations. Generic B lifecycle probes exercise alert/presenter behavior without invoking preference-writing/system-handler entrypoints.
- All static message/body/button keys exist in all six catalogs; each built catalog matches the reviewed source. Native message and informative text must be delivered to actual controls.
- Eight primary predicates and three sub-controls (scroll viewport, appearance delivery, literal window-count multiplicity) discriminate. App-owned under-constrained accessory is red while the same plain native alert is green for ambiguity, with framework INFO retained.
- Requested/effective appearance and requested/actual host dimensions are measured. Geometry is checked at the first observed laid-out frame, after suggestion success/failure, and after the Rename edit.
- Unique temporary config/demo per launch, both app defaults domains compared in memory, every demo removed. Matching preferences are never dumped. Bad native runs retain their literal exits and private receipts.

## Full sample result

Native checks: 1652/1665 passed. Six native exits remain 1, and the clean driver exits 1. Only TS-U1-F1 fails: 12 distinct cell/check pairs, with a second real-path witness making 13 failed assertions. Total six-process wall time: 84.9 seconds. Assertion counts are not feature counts.

| Locale | Passed / checks | Native exit | Product failure |
|---|---:|---:|---|
| de | 750/753 | 1 | Path suggestion, check 2, both sizes |
| ja | 622/624 | 1 | Path suggestion, check 2, both sizes |
| en | 70/72 | 1 | Path suggestion, check 2, both sizes |
| fr | 70/72 | 1 | Path suggestion, check 2, both sizes |
| es | 70/72 | 1 | Path suggestion, check 2, both sizes |
| zh-Hans | 70/72 | 1 | Path suggestion, check 2, both sizes |

## Verdict per check

| Check | Verdict | Evidence |
|---|---|---|
| 1 containment, overlap, text fit | PASS | All A variants and B structural cells; real undersized-accessory control turns this red. |
| 2 screen/host fit | FAIL, retained finding | All A variants pass. B No Such Path exceeds both hosts in every locale. No input reduction or baseline waiver. |
| 3 layout/constraint logs | PASS | App-owned ambiguity checked, framework INFO separate; app-supplied bad accessory fails, plain native control passes; no conflict log lines. |
| 4 ownership/treatment delivery | PASS | Actual attached host / measured popover anchor, actual appearance and host dimensions; isolated mismatch controls. |
| 5 Cancel / file safety | PASS | Correct native Cancel responses and unchanged owned snapshots; injected Cancel commit mutates a real owned file and fails. |
| 6 Return/default | PASS | Native Return resolves to the real default; Reclaim is intended by the dated owner quote and deletes only owned bytes; conflict keeps both. |
| 7 dismissal/responder | PASS | Attached sheet/popover/pending state clears and prior responder returns; suppressed dismissal fails. |
| 8 reopen/no accumulation | PASS | Three cycles per presented cell; literal visible-window IDs/count retained without set collapse; actual stray window fails. |

## Bad controls

Each control uses the same final source/native artifact as the reference pilot. Its native exit 1 stays 1. Validation exit 0 means a delivered corruption turned its previously green named check red, not that product behavior passed. The reference pilot remains natively red for TS-U1-F1.

| Injection | Native exit | Validation exit | Failing checks |
|---|---:|---:|---|
| accessory-short | 1 | 0 | 1, 3 |
| dismiss-failure | 1 | 0 | 5, 7 |
| leaked-window | 1 | 0 | 8 |
| cancel-commits-edit | 1 | 0 | 5 |

## TS-U1-F1: unbounded path-suggestion informative label

Surface: `PaneController.offerSuggestion`, plain No Such Path alert. The informative NSTextField renders both complete paths without a height bound or scroll view. The unchanged four-255-character-component stress input makes the German alert 520x952 pt against the 720x420 host. A separately created, byte-verified existing owned file has an 849-byte path and 180-character components; that alert is 520x776 pt. The real-path witness supplements the original input. Both exceed the minimum host, and the stress body also exceeds the default host. The co-ordinator explicitly requested retaining this red for triage. No production fix is made.

Renders and receipt (private, under this workbench):

- `.build/transient-unit1-findings/TS-U1-F1-stress-path-de.png`
- `.build/transient-unit1-findings/TS-U1-F1-existing-path-de.png`
- `.build/transient-unit1-findings/TS-U1-F1-B-path-suggestion-<locale>-<width>-check2.png` (all 12 final cells)
- `.build/transient-unit1-findings/TS-U1-F1-final-owned-path-proof-de.png`
- `.build/transient-unit1-findings/pilot-native.log`

## Other validation and limits

- Actual inventory gate PASS; scanner controls 19/19; sample wrapper controls 9/9; shell syntax PASS; build PASS with zero new warnings. Normal final commit hooks are reported on the board after their actual terminal.
- Existing transient suite: 53/53, native exit 0, both app defaults unchanged, demo removed.
- Focused real Cleanup-controller Escape: 1/1, native exit 0, response 1001, fixture bytes preserved, intended Delete/Return and Cancel/Escape bindings unchanged.
- Background Escape event delivery to the browser-hosted alert is not claimed. Repeat cycles use the real Cancel button as permitted by check 5. Native popover Escape and the focused real Reclaim Escape are verified. Physical-keyboard/accessibility delivery is not claimed.
- Earlier pilot instrument failures, test-only crash, and failed compile edits remain recorded in `TRANSIENT_SURFACES_RECEIPTS.md`; none is called a product defect.
- In-process native material captures prove structure only; pixel appearance is not approved. No Task 1 baseline or candidate baseline image was committed.
- No full CI, package/release gate, Unit 2 expansion, install, deploy, display-mode change, network/Keychain or real Trash action. No red sample scenario was added to CI; the independent inventory scenario is wired.

## Reproduce privately

Serialize each build/native command with `lockf -k /tmp/commandem-swift-build.lock`, use capped jobs and wrap native commands with `caffeinate -d -i`.

```sh
python3 test/transient_inventory.py
python3 -m unittest discover -s test -p transient_inventory_test.py
python3 -m unittest discover -s test -p transient_surfaces_sample_test.py
python3 test/transient_surfaces_sample.py clean --pilot
python3 test/transient_surfaces_sample.py accessory-short --pilot
python3 test/transient_surfaces_sample.py dismiss-failure --pilot
python3 test/transient_surfaces_sample.py leaked-window --pilot
python3 test/transient_surfaces_sample.py cancel-commits-edit --pilot
python3 test/transient_surfaces_sample.py clean
```

The two clean commands currently exit 1 for TS-U1-F1. A control requires an eligible same-source/native-artifact pilot, complete predicates, unchanged preferences and a new named failure; stale or incomplete references are refused.

Input digest (Swift sources, source/built localization catalogs, inventory, driver and native artifact):
`5355ba3634a0688808815137583b95295701297434be708e1cb4c61142e3b15e`. Machine-readable result: `.build/transient-unit1-ready.json`. Full raw streams: `.build/transient-sample-clean-<locale>.log`; driver receipt: `.build/transient-unit1-delivery-full-driver.log`.
