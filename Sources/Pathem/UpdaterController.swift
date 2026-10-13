import AppKit
import Sparkle

extension Notification.Name {
    /// Posted whenever `pendingUpdateVersion` changes, so the window's update button can
    /// show/hide itself. Broadcast (not per-window) because the updater is app-global.
    static let pathemUpdateStateChanged = Notification.Name(
        "com.scarcrux.pathem.updateStateChanged")
}

/// Wraps Sparkle's standard updater. The updater only starts when the bundle
/// carries a real EdDSA public key (SUPublicEDKey) and feed (SUFeedURL), so
/// source and unsigned builds, which have a placeholder key, launch cleanly and
/// simply report that updates are not configured.
///
/// Uses Sparkle's "gentle reminders" pattern: a scheduled (automatic) update is
/// NOT shown as an interrupting modal. Instead we flip `pendingUpdateVersion` and
/// the window shows a small title-bar button; the actual installer (with its
/// release notes) opens only when the user clicks that button. Nothing is forced.
@MainActor
final class UpdaterController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    let isConfigured: Bool

    /// The most recently reachable updater, so any window's title-bar button can find it
    /// without threading the reference through every window constructor.
    private(set) static weak var shared: UpdaterController?

    /// Non-nil when a scheduled update is waiting for the user to act (drives the button).
    private(set) var pendingUpdateVersion: String?

    static let placeholderKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    override init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        // A release-test launch (the packaged E2E probe) shares this bundle ID with the owner's
        // installed app, so a running updater would fetch the feed and write its state into the
        // owner's real defaults. Tests never start it.
        let isReleaseTest = ProcessInfo.processInfo.environment["PATHEM_RELEASE_TEST"] != nil
        isConfigured = !key.isEmpty && key != Self.placeholderKey && !isReleaseTest
        if isReleaseTest {
            // Unbuffered: the probe ends this process with SIGTERM, which would drop a print().
            FileHandle.standardOutput.write(Data("UPDATER: disabled for release test\n".utf8))
        }
        super.init()
        // Self is now available, so we can be the user-driver delegate for gentle reminders.
        // startingUpdater: false on unconfigured builds, so Sparkle never errors about a
        // missing/placeholder key at launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured, updaterDelegate: nil, userDriverDelegate: self)
        Self.shared = self
    }

    /// Whether Sparkle checks for updates automatically (Settings > Updates). A
    /// no-op on unconfigured builds, which have no real update feed.
    var automaticChecks: Bool {
        get { isConfigured && controller.updater.automaticallyChecksForUpdates }
        set { if isConfigured { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = L("update.notSetUpTitle", "Updates aren't set up for this build")
            alert.informativeText =
                L(
                    "update.notSetUpBody",
                    "This is a source or unsigned build. Download the latest notarized "
                        + "release from GitHub; those builds update themselves.")
            alert.runModal()
            return
        }
        controller.checkForUpdates(sender)
    }

    /// Bring the pending update's installer (with release notes) to the front. Called by the
    /// title-bar update button. Resumes the deferred scheduled-update session.
    func presentPendingUpdate() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    private func setPending(_ version: String?) {
        guard version != pendingUpdateVersion else { return }
        pendingUpdateVersion = version
        NotificationCenter.default.post(name: .pathemUpdateStateChanged, object: self)
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Return false so the standard driver does NOT pop its modal for a scheduled update; we
    /// surface our own quiet title-bar button instead. (User-initiated checks never call this,
    /// so an explicit "Check for Updates…" still shows Sparkle's normal flow.)
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Flip the button on for a scheduled update the user hasn't engaged yet.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !state.userInitiated { setPending(update.displayVersionString) }
    }

    /// The user engaged the update (opened or acted on it); the button has done its job.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        setPending(nil)
    }

    /// Session ended (installed, skipped, or errored): clear the button.
    func standardUserDriverWillFinishUpdateSession() {
        setPending(nil)
    }

    // MARK: Debug

    /// Simulate a pending update so the title-bar button can be exercised on builds where
    /// Sparkle is dormant (no real feed). Test/automation only.
    func debugSetPendingUpdate(version: String?) { setPending(version) }
}
