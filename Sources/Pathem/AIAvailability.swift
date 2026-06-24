import AppKit

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// One place to ask whether the on-device model can be used, and to explain (with a
/// "Learn More" link) why it can't. Every AI feature checks this first so the app
/// degrades gracefully when Apple Intelligence is missing, off, or still downloading,
/// instead of failing silently or with a misleading message.
enum AIAvailability {
    /// Apple's overview page; the alert's "Learn More" opens it for setup details.
    static let infoURL = URL(string: "https://www.apple.com/apple-intelligence/")!

    /// A human-readable reason the model is unavailable, or nil when it's ready.
    static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return nil
                case .unavailable(.deviceNotEligible):
                    return L("ai.unavail.device", "This Mac doesn’t support Apple Intelligence.")
                case .unavailable(.appleIntelligenceNotEnabled):
                    return L(
                        "ai.unavail.notEnabled",
                        "Apple Intelligence is turned off. Turn it on in System Settings, under Apple Intelligence & Siri.")
                case .unavailable(.modelNotReady):
                    return L(
                        "ai.unavail.notReady",
                        "The on-device model is still downloading. Try again in a little while.")
                @unknown default:
                    return L("ai.unavail.generic", "Apple Intelligence isn’t available right now.")
                }
            }
        #endif
        return L("ai.unavail.os", "This needs macOS 26 with Apple Intelligence.")
    }

    /// True when the on-device model is ready to use.
    static var isAvailable: Bool { unavailableReason() == nil }

    /// Explain why an AI feature is unavailable, with a "Learn More" button that opens
    /// Apple's setup page. `feature` is the alert title (e.g. "Organize with AI is unavailable").
    @MainActor
    static func presentUnavailable(_ feature: String, reason: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = feature
        alert.informativeText = reason
        alert.addButton(withTitle: L("ai.learnMore", "Learn More"))
        alert.addButton(withTitle: L("common.ok", "OK"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(infoURL) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
