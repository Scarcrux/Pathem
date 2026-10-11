# Background context menus: acceptance before sampling

Trigger: the Finder inventory records missing blank-space View/Arrange By menus.
Inspection also finds that only list/icon content implements grouping: gallery,
column and tree use the protocol's no-op, but registry Arrange actions are enabled.
That is a hypothesis about delivered UI behavior until the sample runs.

## Criteria

- Launch a real browser window over disposable files; require the actual requested
  content mode and listing in each of the five views. Empty selection must really
  be delivered before inspecting the installed context menu.
- Background View and Arrange By submenus contain the existing five mode and five
  grouping command IDs exactly once. Selected-item context must not acquire these
  background-only controls. Clearing selection restores them without reconstruction.
- List and Icons accept grouping and actually render differing Kind sections/rows
  versus None. Gallery, Columns and Tree must reject all five Arrange commands,
  leave the grouping preference unchanged and expose disabled menu actions. This is
  a capability boundary, not a promise to implement grouping in those views.
- Dispatch the real submenu items through this window's responder chain, not a
  fabricated command. All 25 source/destination mode pairs must deliver the target
  mode and listing; checkmarks and active-pane targeting must follow actual content.
  Switching panes must not mutate the inactive pane's mode or grouping.
- Hiding/reordering submenu tokens must work in installed menus, including saved
  orders predating the additions and duplicate/obsolete saved tokens. Each valid
  entry appears once, keeping its first saved position. Visible separators must
  not lead, trail or double.
- Distinguishing controls: current mode checked, different mode unchecked; Kind
  renders groups, None is flat; unsupported grouping is refused; selected context
  hides both background menus. A missing menu, no-op accepted action or undelivered
  listing is a failure, never a SKIP.

The sample first runs against unchanged production menus/commands. Only after its
causal failures are recorded should implementation and the expanded matrix run.
Run full local CI and the signed-package launch checks before landing. These checks
do not establish native menu placement, physical mouse tracking or VoiceOver
acceptance. No installed app, system preferences, keychain, permissions or live
storage/provider changes.

## Initial sample

Unchanged production behavior fails 13/24 checks: both background menus are absent
in all five delivered modes; Gallery, Columns and Tree each accept Arrange Kind
and mutate the grouping preference even though their content inherits a no-op.
All actual-mode, listing and empty-selection delivery checks pass (11/24). The
mechanism is missing shared submenu entries and unconditionally enabled registry
actions over unsupported content. Native menu tracking is not implicated.

Saved-order sample passes 5/6 controls: legacy orders acquire new tokens correctly,
but duplicated saved entries create duplicate commands and parents. The ordering
function filtered validity without uniqueness. Retain only each token's first
saved position and append missing defaults exactly once. No preferences files
outside the disposable test configuration are edited.

Corrected small sample passes 24/24 UI checks and 6/6 ordering tests. Expanding the
actual-command transition matrix is now justified by delivered positive/negative
controls, not merely successful construction.

Recompiling the engine exposes seven additional owned warning fingerprints (eight
declarations) that the previous cached inventory did not emit. All say that an
unsafe static declaration is unnecessary for an SDK-Sendable type. The strict gate
rejects that log (19 owned, 12 known, seven unrecognized); no exception is added.
History records these statics as an older CI SDK compatibility repair (`e605748`).
Use compiler-checked declarations on the locally verified Swift 6.4+ path, retaining
the older compiler fallback and exactly the same once-created formatter/regex/context
values. The older SDK branch is preserved, not reverified on an unavailable toolchain;
no broader SDK/version portability claim. Fifteen previously measured unresolved
fingerprints remain, and the old partial inventory must not be called exhaustive.

First expanded run fails 114/263 checks. Fifteen saved-order/hide failures across
all five actual views expose a separate production dispatch bug: hiding/ordering
methods were only protocol-extension defaults, not protocol requirements. Calling
through `PaneContentView` therefore selects the no-op, despite each view owning a
real implementation. Add the two requirements so the existing implementations are
the witnesses. Remaining validation/dispatch failures are not yet attributed to
production: run a one-mode sample logging actual focus, resolved target, capability
and enabled state before changing their mechanism.

One-mode trace passes 25/35: all three customization checks now pass, while manual
validation resolves the actual Browser controller and returns enabled=true, but
effective submenu flags remain false on this non-key-window host. The mechanism
is not yet established; the validator result argues against a registry defect.
Try disabling automatic
validation on the test menus only, then apply the same real-window responder-chain
verdict to each item. Production automatic validation is unchanged; actual native
tracking remains unverified. The supported/unsupported controls must still differ.

Disabling automatic validation alone leaves the sample at 25/35; it is not a fix.
Next test the hypothesis that a parent's state affects effective child enablement:
restore a test parent's ability to validate children, then derive its
state from their real responder-chain verdicts. Never force every action enabled.

The parent-restoration attempt also fails 25/35, so neither adjustment is retained
or claimed as a cure. The supported validator returns true and target resolution
reaches the Browser controller, while effective submenu flags do not hold outside
native tracking. That internal AppKit behavior is not causally resolved here.
Final probe checks the actual target's validation verdict and dispatches each real
item through the same window's responder chain; it does **not** claim native popup
enablement/appearance. No automatic/enabled flags are rewritten by this probe.
This follows the window-originated contextual routing described by
[Apple's menu-validation documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/EnablingMenuItems.html).
The differing unsupported controls remain mandatory, and native tracking remains
a separate acceptance boundary.

Corrected one-mode probe passes 35/35, including real Kind headers and None flat
items. The full matrix passes 263/263: all 25 actual source/destination transitions,
mode/group checkmarks, supported-versus-refused grouping, selected/background
visibility, customized installed menus and right-side targeting. Actual effective
native submenu enablement/physical tracking is still not claimed.

Before final CI, force a debug recompile with an otherwise unused
`PATHEM_WARNING_INVENTORY` compilation condition and bounded build jobs. Verify the
condition has no feature branch, its delivery appears in compiler commands, owned
sources are recompiled and the exact warning gate accepts the emitted diagnostics.
This avoids calling a zero-warning warm cache an exhaustive source inventory.
Known warning exceptions may remain; any new/unparsed owned diagnostic is failure.

That inventory criterion fails: the fresh build reveals fourteen additional
fingerprints (two TorrentKit array C-string deprecations and twelve unchanged
SecureTransport device-bridge deprecations). See `COMPILER_STATICS_TESTING.md` for
the recorded red result, bounded decoding fix, amended exact TLS-debt inventory,
and permanent fresh CI compilation. This slice does not claim warning-free source.

Final full local CI exits zero: 15 XCTest tests and the 779-case Swift Testing run;
live FTP/SFTP, public DHT and Transmission tests remain explicitly skipped. Debug
E2E passes 61 checks with one allowed browser-opacity skip and zero failures. The
new mandatory background scenario passes 263/263 again, alongside search 59/59,
Finder 198/198, layout 161/161 and transient 52/52. Packaged current-host release
passes 9/9, including signature, launch and visible window. Debug/release warning
union has 27 exact documented fingerprints, zero new/unparsed; native tracking,
older SDK and physical/provider boundaries remain open. No install or publication.
