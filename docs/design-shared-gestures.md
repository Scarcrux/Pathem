# Shared gestures across Commandem and Pathem

Pathem Mission 47 (`m-e1443252`), coordinated with Commandem Mission 661. Criteria written before implementation, 2026-10-10.

Trigger: the owner identified Pathem's existing gesture system and requested a
module used by both apps. Source inspection established duplicated dominant-axis
geometry, collapsed direction strings, binding overlays and recording canvases.
Pathem's tracker retains every point; Commandem's recognizer already bounds its
trail. This is consolidation, not a new action policy or gesture mapping.

Mechanism: a standalone system-framework-only Swift package owns stroke capture,
bounded trails, binding resolution and an optional AppKit recording/practice
canvas. App adapters retain action catalogs, input ownership, origin validation,
config formats, native fallback and styling. Commandem remains the canonical
package location; Pathem carries a byte-pinned local copy so either checkout can
build independently. A manifest verifier refuses changed package bytes. Updates
are explicit copies from the canonical package, never parallel edits.

## Criteria

- S1: existing Commandem gesture tests preserve all 160 canonical strokes,
  threshold/tie/anchor behavior, fifth-segment refusal, timeouts, origin checks,
  one terminal release, cancellation and bounded chronological trail.
- S2: Pathem adapter preserves default navigation/file-flick actions, flat JSON
  overrides, empty-string unbinding, 18/44 point thresholds and first-four
  overflow. Dense streaming capture is bounded and equals the saved reducer's
  output for valid samples. Ordinary click and menu fallback stay in app code.
- S3: both apps invoke the same core and recording canvas. No sibling checkout,
  network package, credential or executable is needed to build the package.
- S4: recording previews before release, emits at most one callback, invokes no
  app action, clears bounded capture, and Escape/deactivation/removal cancel.
  Native tests park windows at (-10000,-10000), with isolated callbacks/styles.
- S5: pinned manifest verification is GREEN for the exact package and RED after
  one source-byte change; both repository copies are byte-identical.
- S6: full local Commandem Swift hook plus CLI/e2e and Pathem Swift test/build,
  formatting and localization gates pass before normal commit/land. Record any
  unrelated failure or foreign-primary integration blocker without takeover.

Negative controls: Commandem must reject a fifth direction while Pathem returns
its four-direction prefix; subthreshold jitter must not recognize; Escape must
produce zero recording callbacks; mutated package must fail its pin check.

Confidence boundary: scripted core/native recording checks establish source
behavior, not physical mouse calibration or installed-app acceptance. Pathem
native navigation/flick ownership, menu fallback and app-level interruption
policy remain local. Mobile delivery is not newly enabled. No provider calls,
installation, restart, publication or push belongs to this unit.

## Observed integration results before full gates

The standalone package initially passed 6 checks. First Commandem affected gate:
recognition/binding/sequence/native controls passed, but the mounted Settings
probe failed because it searched for the retired DesktopGesturePadNSView. The
updated probe drove the actual shared canvas and exposed two adapter issues:
synthetic right-family NSEvents report buttonNumber 0, and the intrinsic
120-point AppKit canvas exceeded the existing 80-point SwiftUI allocation.
The boundary now derives left/right identity from explicit event family, with a
left-button refusal control for Commandem; sizeThatFits retains the host's
80-point surface. These failures are retained in the local gate receipts.
The final mounted probe also checks live action preview, inert recording,
explicit Apply, and Escape preserving the binding.

Pathem's roadmap CLI normalized all legacy phase/campaign records when adding
this unit. The bench restores the exact unrelated legacy bytes and appends only
its selected new phase/task with the generated stable IDs. Read-only roadmap
inspection resolves that unit correctly; no unrelated migration is bundled.
Pathem primary already has four foreign dirty files, including a separate
53-Mission roadmap; none are imported, reset or overwritten by this work.

## Local integration boundaries

Pathem receives the exact standalone package with manifest SHA256
9fe9ab9357240c3ecc9617a294a43ceccad0e88dd3ffc3118818965f2e486282.
MouseGesture.reduce, streaming MouseGestureCapture, the native tracker and the
Settings recorder invoke that package. File flick start/end logic, command
availability, selection, context-menu fallback and flat gestures.json remain
in existing Pathem handlers. Generic binding overlays preserve empty-string
unbinding and all default command IDs. The shared recorder retains either-button
capture, Pathem's localized idle label, live theme accent and empty-click clear.
It adds bounded capture and Escape/lifecycle cancellation to recording only;
production flick/navigation interruption policy is not newly certified.

New tests compare the streaming engine with an independent historical geometry
oracle on 10,000+ samples and preserve the prefix/flick/JSON compatibility cases.
Shared native canvas tests are part of the normal full Swift hook. Original
Commandem mounted-test failures, subsequent adapter fixes and front-matter e2e
refusal are retained in the coordinated packet; no failed result is hidden.

The roadmap CLI initially converted all legacy records. This unit keeps all 46
original phase records/raw bytes and appends only its selected new phase/task.
A separate foreign dirty primary (managed instructions plus modern 53-Mission
roadmap) remains untouched. Normal land must report that blocker if it persists.
Acceptance means local complete normal tests/build and exact pinned bytes;
installed-app and physical-input claims remain outside this unit.

## Reproduced commit-hook integration defect

First normal hook failed before tests: every remote dependency checkout reported
unable-to-read-tree. The pinned SwiftTerm commit is present in the owned package
repository (clean git cat-file exit0), but the same lookup under hook-inherited
GIT_DIR/GIT_WORK_TREE fails128 against Pathem. The hook did not clear Git's
repository-routing variables before SwiftPM's own Git subprocesses. This is a
convicted hook environment defect, not a provider/network or gesture failure.
The mandatory hook now scrubs the same six Git routing variables as Commandem
before exec'ing the unchanged complete Xcode Swift test command. No gate is
skipped, no shared/global cache is reset, and no foreign index is touched.
The actual initial failure and discriminating lookups are retained in receipts.

The corrected hook reached compilation and exposed a second inherited build
boundary: unconstrained SwiftTerm from1.13 selected1.99, where getTerminal was
removed, while the unchanged PathemTerminal source still calls that method.
Read-only Git source controls find getTerminal declarations at the originally
specified v1.13.0 tag and none at the freshly selected1.99 commit. Pin the already
specified compatible1.13.0 exactly instead of changing unrelated terminal UI.
This makes an independent clone reproducible; full test/build acceptance remains
required on that pin. Both genuine gate failures remain in the local receipts.

The first Git probe used an unprefixed tag and a too-broad method substring;
that probe is invalid evidence. Corrected exact-method controls at v1.13.0
succeed, and at the selected1.99 revision return1 (no such method). The first
pin retry then exposed stale SwiftPM build-plan traits: PortableGraphics from
1.99 was still applied to1.13, which declares no traits. Reset only this owned
workbench's regenerable SwiftPM state before rerunning the normal hook; shared
caches, source, foreign records and installed applications remain untouched.

## Final local gate verdicts

S1 PASS in Commandem204 affected checks and mandatory complete Swift hook; its
source54867e97 is normally landed. S2 PASS in Pathem's full unfiltered normal
Swift hook at94f53d0 (includes the four named compatibility tests); no filtered
substitute or skipped failing suite. S3 PASS by exact9fe9ab93 manifest comparison
and independent local builds. S4 PASS by the actual shared native callback tests
and mounted Commandem Settings preview/Apply/Escape/geometry capture; physical
Pathem menu/flick interruption behavior is not newly certified. S5 PASS: exact
package copies verify and changed-byte pin control refuses. S6 PASS locally:
Pathem normal formatting/pin/full Swift/localization hooks and explicit full build
(3.66s); Commandem full Swift plus CLI38.725s/e2e61.418s. All prior failed controls
and build attempts remain in receipts. Installation/restart/push remain absent.

Initial normal land was refused by the unrelated dirty primary commandem.toml.
Final integration preserves the original three instruction files byte-for-byte
and all53 foreign modern Mission records/other fields. A private0700 archive
retains original0600 files. Only owned gesture records may be inserted/replaced
by their stable ID when restoring pending state; foreign changes are not committed.
Actual normal land status and resulting main SHA are recorded on the scoped board.
