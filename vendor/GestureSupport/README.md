# GestureSupport 0.1.0

Standalone Swift package for Commandem and Pathem. `GestureSupport` is
Foundation-only (macOS/iOS); optional `GestureRecording` uses AppKit for a
bounded recording/practice canvas, live preview and Escape/lifecycle cancellation.
It never dispatches an action. There are no remote or app dependencies.

Commandem `menubar/GestureSupport` is the canonical source. Pathem vendors the
entire package under `vendor/GestureSupport`, as a pinned local SwiftPM dependency.
Change canonical source, run its tests, explicitly refresh `manifest.json` hashes,
then copy the exact package to Pathem. Do not edit the vendored copy independently.
`python3 verify.py` rejects missing, extra or modified source files; `--compare`
also verifies that another package carries the same pinned bytes. Each app's
normal test hook verifies its copy and runs the package's tests.

Adapters own command catalogs, eligibility, settings, persistence and capture
surfaces. `BindingTable` resolves candidates without invoking commands. Disabled
overrides never resurrect defaults. `StrokeCapture` uses y-up logical coordinates,
a square threshold, horizontal diagonal ties and repeated-direction collapse.
Storage is bounded to four semantic segments and 256 chronological visual points.
Overflow is explicit: Commandem uses `.reject`, Pathem uses `.prefix`. The optional
duration and cancellation reason are supplied by the caller; Pathem's legacy
batch/stream reducer has no duration limit. Invalid samples refuse recognition.

The recording control accepts either mouse button, previews supplied action titles
before release, and returns at most one stroke. Empty-click handling is a host
callback (Pathem clears a binding; Commandem does nothing). A new button cycle,
Escape, window/app deactivation, timeout or removal retires the old recording.
The canvas does not impose the host app's production capture or menu policy.

Run `swift test` in this package, or the owning app's full test gate. Native
recording tests use off-screen windows. Physical mouse calibration and installed
app behavior remain separate acceptance evidence.
