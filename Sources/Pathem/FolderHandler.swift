import AppKit
import UniformTypeIdentifiers

/// Reads and sets the system's default application for opening folders (`public.folder`).
/// Making Pathem the default redirects "open this folder" actions (a folder double-click,
/// `open <dir>`, an app that opens a directory) to Pathem instead of Finder. It does NOT
/// affect "Reveal in Finder" (macOS routes that to Finder with no override). Fully
/// reversible: set Finder back as the default.
enum FolderHandler {
    static let finderBundleID = "com.apple.finder"

    /// Whether Pathem is currently the default handler for folders.
    static var isPathem: Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Point the default folder handler at Pathem (`toPathem`) or back at Finder. Throws if the
    /// target app can't be found or LaunchServices refuses the change.
    static func setDefault(toPathem: Bool) async throws {
        let appURL: URL
        if toPathem {
            appURL = Bundle.main.bundleURL
        } else if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) {
            appURL = finder
        } else {
            throw CocoaError(.fileNoSuchFile)  // Finder somehow not found
        }
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .folder)
    }
}
