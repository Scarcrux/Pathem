import AppKit
import UniformTypeIdentifiers

/// Reads and sets the system's default application for magnet links (the `magnet:` URL scheme) and
/// `.torrent` files. Making Pathem the default sends a magnet click, or an opened `.torrent`, straight
/// to Pathem's Torrents panel instead of another client. macOS has no System Settings UI for URL
/// scheme handlers, so this is the place to change it; it's reversible from another client's settings.
enum MagnetHandler {
    /// A syntactically valid but inert magnet link, used only to ask LaunchServices which app would
    /// open one (all-zero info hash -> matches no real torrent).
    private static let probe = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000")!

    /// Whether Pathem is currently the default handler for magnet links.
    static var isPathem: Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Make Pathem the default for magnet links, and best-effort for `.torrent` files too. Throws if
    /// LaunchServices refuses the scheme change; the `.torrent` type is best-effort because that UTI
    /// isn't registered on every system.
    static func makeDefault() async throws {
        let app = Bundle.main.bundleURL
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet")
        if let torrent = UTType("org.bittorrent.torrent") {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: torrent)
        }
    }
}
