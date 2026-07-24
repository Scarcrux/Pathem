import AppKit

/// Installs (and removes) the on-PATH `pathem` command as a symlink to the CLI bundled inside the
/// app, so `pathem reveal <path>` works from any terminal. The symlink can't live in the app's own
/// `Contents/MacOS/` (a lowercase `pathem` would collide with `Pathem` on a case-insensitive volume),
/// so it points there from a real PATH directory. Non-invasive and fully reversible: removing it just
/// deletes a symlink we own, never a real file or one pointing elsewhere.
enum PathemCLIInstall {
    static let commandName = "pathem"

    /// The CLI binary bundled inside the running app (nil if not packaged, e.g. a bare `swift run`).
    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pathem-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Directories we'll consider for the symlink, in preference order: the usual PATH bins first,
    /// then user-owned fallbacks that don't need admin rights.
    static func candidateDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin"),
        ]
    }

    /// Whether `link` is a symlink that resolves to our bundled CLI (so remove() knows it's ours).
    static func linkPointsToUs(_ link: URL, bundled: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = dest.hasPrefix("/") ? dest : link.deletingLastPathComponent().appendingPathComponent(dest).path
        return URL(fileURLWithPath: resolved).standardizedFileURL == bundled.standardizedFileURL
    }

    /// The existing `pathem` symlink that points at our bundled CLI, if one is installed anywhere in
    /// the candidate directories.
    static func installedLink() -> URL? {
        guard let bundled = bundledCLI else { return nil }
        for dir in candidateDirectories() {
            let link = dir.appendingPathComponent(commandName)
            if linkPointsToUs(link, bundled: bundled) { return link }
        }
        return nil
    }

    static func isInstalled() -> Bool { installedLink() != nil }

    enum InstallError: LocalizedError {
        case notBundled
        case noWritableDirectory
        case occupied(URL)  // a real file (not our symlink) already sits at the target

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return L("cli.err.notBundled", "The pathem command isn’t available in this build.")
            case .noWritableDirectory:
                return L(
                    "cli.err.noDir",
                    "No writable directory on your PATH was found (tried /usr/local/bin, /opt/homebrew/bin, ~/.local/bin, ~/bin). Create one and try again.")
            case .occupied(let url):
                return String(
                    format: L("cli.err.occupied", "Something already exists at %@ that isn’t Pathem’s link. Remove it first."),
                    url.path)
            }
        }
    }

    /// Install the symlink into the first writable candidate directory. Returns the created link.
    /// Idempotent: if already installed at a valid spot, returns that.
    @discardableResult
    static func install() throws -> URL {
        guard let bundled = bundledCLI else { throw InstallError.notBundled }
        if let existing = installedLink() { return existing }
        let fm = FileManager.default
        for dir in candidateDirectories() where fm.isWritableFile(atPath: dir.path) {
            let link = dir.appendingPathComponent(commandName)
            if fm.fileExists(atPath: link.path) {
                // Only replace a symlink that's already ours; never clobber a real file.
                guard linkPointsToUs(link, bundled: bundled) else { throw InstallError.occupied(link) }
                return link
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
            return link
        }
        throw InstallError.noWritableDirectory
    }

    /// Remove the `pathem` symlink if (and only if) it's ours.
    static func remove() throws {
        guard let link = installedLink() else { return }
        try FileManager.default.removeItem(at: link)
    }
}
