import AppKit
import UniformTypeIdentifiers

/// Opening a file with a chosen app, and changing which app the system uses for a content
/// type (Finder's "Change All"). Both opener surfaces go through here so a refused or
/// failed system change is reported instead of silently ignored.
@MainActor
enum FileOpening {
    /// Root types that stand for every file macOS can't otherwise identify (a `.env` file is
    /// `public.data`). A system default for one of these would cover every such file, so it
    /// is refused rather than attempted.
    static func isGeneric(_ type: UTType) -> Bool {
        [UTType.data, .item, .content, .compositeContent].contains(type)
    }

    #if DEBUG
    /// When non-nil, opens and system-default changes are recorded here instead of launching
    /// an app or changing LaunchServices (docs/OPENER_RULES_TESTING.md).
    static var debugRequests: [String]?
    #endif

    static func open(_ url: URL, with app: URL?) {
        #if DEBUG
        if debugRequests != nil {
            debugRequests?.append("open \(url.path) with \(app?.path ?? "system")")
            return
        }
        #endif
        if let app {
            NSWorkspace.shared.open(
                [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func setSystemDefault(app: URL, for type: UTType) async throws {
        #if DEBUG
        if debugRequests != nil {
            debugRequests?.append("system-default \(app.path) \(type.identifier)")
            return
        }
        #endif
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }

    static var genericTitle: String {
        L("opener.genericTitle", "This kind can’t have a system-wide default")
    }

    static func genericBody(_ name: String) -> String {
        String(
            format: L(
                "opener.genericBody",
                "macOS treats “%@” as a generic file, so a system default would apply to every file it can’t identify. In Always Open With, choose “All files named …” instead."
            ), name)
    }

    static var failedTitle: String {
        L("opener.systemFailedTitle", "Couldn’t change the default app")
    }
}
