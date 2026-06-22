import AppKit
import Sparkle

/// Wraps Sparkle's standard updater. The updater only starts when the bundle
/// carries a real EdDSA public key (SUPublicEDKey) and feed (SUFeedURL), so
/// source and unsigned builds, which have a placeholder key, launch cleanly and
/// simply report that updates are not configured.
@MainActor
final class UpdaterController: NSObject {
    private let controller: SPUStandardUpdaterController
    let isConfigured: Bool

    static let placeholderKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    override init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        isConfigured = !key.isEmpty && key != Self.placeholderKey
        // startingUpdater: false on unconfigured builds, so Sparkle never errors
        // about a missing/placeholder key at launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't set up for this build"
            alert.informativeText =
                "This is a source or unsigned build. Download the latest notarized "
                + "release from GitHub; those builds update themselves."
            alert.runModal()
            return
        }
        controller.checkForUpdates(sender)
    }
}
