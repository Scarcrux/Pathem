import Foundation

/// Compress and extract archives by shelling OUT OF PROCESS to the BSD-licensed
/// command-line tools that ship with macOS (`/usr/bin/zip`, `/usr/bin/tar`,
/// `/usr/bin/ditto`) — never a GPL library, and untrusted-archive parsing stays
/// out of the Full-Disk-Access process. Compress/Extract first; browse-into is a
/// later step.
public enum Archiver {
    public enum ArchiveError: Error, Sendable {
        case nothingToCompress
        case unsupported(String)
        case tool(code: Int32, message: String)
    }

    /// Extensions Extract understands.
    public static func canExtract(_ url: URL) -> Bool {
        kind(of: url) != nil
    }

    private enum Kind { case zip, tar }

    private static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        for suffix in [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst"]
        where name.hasSuffix(suffix) {
            return .tar
        }
        return nil
    }

    /// Zip the given items (which must share a parent folder) into `destination`.
    /// `.DS_Store` and `__MACOSX` are always excluded; `excludeGit` also drops
    /// `.git` directories for a clean source archive.
    public static func compress(_ urls: [URL], to destination: URL, excludeGit: Bool = false) async throws {
        guard let parent = urls.first?.deletingLastPathComponent() else { throw ArchiveError.nothingToCompress }
        let names = urls.map(\.lastPathComponent)
        guard !names.isEmpty else { throw ArchiveError.nothingToCompress }
        var args = ["-r", "-X", "-q", destination.path] + names
        args += ["-x", "*.DS_Store", "-x", "__MACOSX*", "-x", "*/__MACOSX/*"]
        if excludeGit { args += ["-x", "*.git/*", "-x", "*/.git/*"] }
        // zip stores paths as given, so run it with the parent as the working
        // directory and pass bare names for a clean archive layout.
        let (_, status, err) = try await RemoteRunner.run("/usr/bin/zip", args, cwd: parent)
        guard status == 0 else { throw ArchiveError.tool(code: status, message: err) }
    }

    /// Extract `archive` into `directory` (zip via ditto, tar family via bsdtar).
    public static func extract(_ archive: URL, to directory: URL) async throws {
        guard let kind = kind(of: archive) else {
            throw ArchiveError.unsupported(archive.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result: (Data, Int32, String)
        switch kind {
        case .zip:
            result = try await RemoteRunner.run(
                "/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        case .tar:
            // bsdtar auto-detects gzip/bzip2/xz/zstd compression.
            result = try await RemoteRunner.run(
                "/usr/bin/tar", ["-x", "-f", archive.path, "-C", directory.path])
        }
        guard result.1 == 0 else { throw ArchiveError.tool(code: result.1, message: result.2) }
    }
}
