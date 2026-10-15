# Sidebar transfers: regression contract

Trigger: cut files cannot be pasted into favorites/other sidebar folders, and a
plain drag unexpectedly copies. Source evidence: the sidebar has no Paste action;
file Paste takes only the active pane; sidebar, breadcrumb and Up drop handlers
hard-code Command=move independently of Settings > General.
Read-only inspection of the saved drag preference confirmed that move was already
enabled; no owner preferences were changed. New tabs also omitted that setting
from their shared content-configuration path, so they could fall back to copy.

## Criteria written before execution

The focused native-window sample must use disposable folders, an isolated config
root and a private pasteboard. It must dispatch the actual sidebar menu action,
not call FileOperations directly. A cut file must move to the clicked folder even
while the pane/selection points elsewhere; a copied file must retain its source.
Keyboard Paste with sidebar focus must target its selected folder. Undo must
restore a cut file. Empty/text clipboard, missing folders and an in-flight
transfer must disable Paste. Inline text editing must retain text Paste.

Drag validation and acceptance must agree on move/copy for both preference values
and Command inversion. The sample must deliver real file URLs through dragging
info to sidebar, breadcrumb and Up handlers; their transfer callbacks must report
the same operation shown by validation. Copy-only sources must never move, and a
source offering no supported operation must be rejected. Reordering favorites,
tagging, AirDrop and Trash retain their separate semantics.

Defaults must move; an explicitly saved copy preference must survive decoding.
Preference changes must reach existing panes, newly created panes, sidebar and
navigation drop targets. The wider gate is the local engine suite/build and
existing scripted UI scenarios. A missing Paste action, wrong destination,
source loss during copy, inconsistent cursor/action or unsupported operation
accepted is a failure, not an environmental skip.

## Evidence

First sample: 23/38 checks passed, including real cut/copy, clicked destinations,
undo, keyboard Paste, invalid-clipboard controls, inline rename and both new-tab
preferences. All 12 drag rows failed the treatment-receipt condition: calling
`sendEvent` before `NSApplication.run` did not establish/deliver the event. This is
an instrument failure, not evidence of drag correctness. A separate small AppKit
probe confirmed that posting then dequeuing with `nextEvent` changes
`currentEvent` from nil to Command; the revised scenario verifies that receipt
before invoking any destination delegate. A second sample passed 24/38 but
incorrectly required event object identity: a small independent probe established
that AppKit clones queued NSEvents. Receipt now compares a unique payload and the
actual current-event modifiers, not pointer identity. Folder expansion also waits
through the inline-rename reload before resolving the current tree node.
Initial build failures (an edit during
compilation and missing AppKit override/isolated-conformance declarations) were
corrected; a new Selector warning was removed rather than allowlisted.

The keyed-event payload itself was truncated by AppKit's queue reconstruction;
the instrument now posts a tagged application-defined event (independently
verified to preserve its integer payload and Command flags), and asserts actual
receipt before the delegates run. That revision passed 30/38, including the real
sidebar move and all four unsupported-mask refusals. The remaining eight positive
rows are being checked with canonical filesystem-location comparisons rather than
URL representation equality (sidebar directory URLs include trailing slashes).

Final focused sample: PASS 38/38. The event receipt log proves both payload and
current modifiers; each matrix row logs sidebar/breadcrumb/Up operations, expected
operation, and callback count. All 12 policy/source-mask rows agree; four negative
rows reject the drop and invoke zero callbacks. Real cut-to-favorite, copy-to-system
folder, keyboard Paste, inline rename routing, undo and expanded-child drag move
all pass. The fresh local warning gate passes (15 known, zero new), as do 15
XCTest cases and 783 Swift Testing cases in 161 suites, including the new
missing-key/default-move and explicit-copy JSON round-trip regression. Subsequent
product and local package results follow.
The first full CI run exposed an integration omission in this change: the shell
configuration-root probe's allowlist did not yet recognize the new scenario flag
(`unknown guard flag`, exit 2). The application refusal guard was already wired;
the probe allowlist was corrected rather than removing the safety check. The
first full run is therefore not claimed as passing.
The corrected configuration-root probe passes 10/10 (both missing and unsafe
roots for all five flags). The first full debug E2E run finished 65 PASS / 1 SKIP /
2 FAIL: the allowlist omission and a WebDAV fixture-start failure, with no traceback
or cause established. All app interaction scenarios passed, including sidebar
38/38, existing UI 49/49, search 170/170, Finder 198/198 and background menus 263/263.
The entire product gate and local package gate were then rerun; the source/engine
checks remain the previously verified identical Swift code, not a second claimed
monolithic `make ci` pass.
Product rerun: PASS, 67 passed / 1 explicit SKIP / 0 failed. The skip rejects a
mostly-transparent cached browser screenshot rather than claiming native visual
acceptance. WebDAV CRUD passes 5/5 without code changes, leaving its initial
fixture-start cause unknown. The sidebar scenario repeats 38/38 and configuration
refusal guards pass 10/10. The local release-package result follows.
Local ARM64 release-package gate: PASS 14/14, zero skips/failures, including
signature, hardened runtime, all six languages, isolated configuration refusal,
external launch/liveness and a visible window. The installed app was neither
replaced nor restarted; no signing credentials, notarization or publication were
used. All normal gate components now pass individually after the recorded shell
allowlist correction; the initial monolithic `make ci` remains a recorded failure.

No owner files, clipboard or installed application are used or replaced by the
regression scenario. Physical pointer dragging, third-party app source behavior
and online-only cloud hydration are not inferred from this deterministic scenario.

Optional strict style lint also reports legacy trailing-comment/forEach diagnostics
in touched files (the same classes reproduce from HEAD's BreadcrumbBar). The normal
automatic formatter is applied; no repository-wide strict-style-clean claim is made.
