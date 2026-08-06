import AppKit
import AppRelaunch

/// App-global latch for AppRelaunch's one-shot "a newer build is installed" signal.
///
/// `AppRelaunch.watch` fires its callback at most once, minutes into the run, off on a utility
/// queue (hopped to the main actor). But the affordance is per-window -- every window's title-bar
/// accessory (`UpdateButtonAccessory`) needs to know, including windows opened after the signal
/// fired. So the callback records the `StaleBuild` here and posts `.pathemUpdateStateChanged`;
/// existing buttons refresh live, and a newly-built button reads `current` on creation.
@MainActor
enum StaleBuildState {
    /// The stale-build the watcher found, or nil until it fires. Set once.
    private(set) static var current: AppRelaunch.StaleBuild?

    static func record(_ stale: AppRelaunch.StaleBuild) {
        current = stale
        NotificationCenter.default.post(name: .pathemUpdateStateChanged, object: nil)
    }
}
