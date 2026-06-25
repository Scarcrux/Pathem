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

    // RAR and 7-Zip need third-party CLI tools (The Unarchiver's `unar`/`lsar`, p7zip's
    // `7z`); we invoke whatever the user installed (never bundle or link GPL code) and
    // degrade gracefully when they're absent.
    private static func toolPath(_ names: [String]) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            for name in names {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
    static var unarTool: String? { toolPath(["unar"]) }
    static var lsarTool: String? { toolPath(["lsar"]) }
    static var sevenZipTool: String? { toolPath(["7z", "7za", "7zz"]) }
    /// Whether a 7-Zip archive can be created on this machine (p7zip installed).
    public static var canMakeSevenZip: Bool { sevenZipTool != nil }

    private enum Kind { case zip, tar, unar }

    private static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        for suffix in [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst"]
        where name.hasSuffix(suffix) {
            return .tar
        }
        // rar/7z only count as extractable when the tool to do it is present.
        if name.hasSuffix(".rar") || name.hasSuffix(".7z") { return unarTool != nil ? .unar : nil }
        return nil
    }

    /// Zip the given items (which must share a parent folder) into `destination`.
    /// `.DS_Store` and `__MACOSX` are always excluded; `excludeGit` also drops
    /// `.git` directories for a clean source archive.
    public static func compress(_ urls: [URL], to destination: URL, excludeGit: Bool = false) async throws {
        guard let parent = urls.first?.deletingLastPathComponent() else { throw ArchiveError.nothingToCompress }
        // Prefix each name with "./" so a file named "-foo" isn't read as a zip option
        // (zip stores the "./" -prefixed name without the leading "./").
        let names = urls.map { "./\($0.lastPathComponent)" }
        guard !names.isEmpty else { throw ArchiveError.nothingToCompress }
        var args = ["-r", "-X", "-q", destination.path] + names
        args += ["-x", "*.DS_Store", "-x", "__MACOSX*", "-x", "*/__MACOSX/*"]
        if excludeGit { args += ["-x", "*.git/*", "-x", "*/.git/*"] }
        // zip stores paths as given, so run it with the parent as the working
        // directory and pass bare names for a clean archive layout.
        let (_, status, err) = try await RemoteRunner.run("/usr/bin/zip", args, cwd: parent)
        guard status == 0 else { throw ArchiveError.tool(code: status, message: err) }
    }

    /// Create a 7-Zip archive from items sharing a parent, via p7zip's `7z`. Throws
    /// `unsupported` when 7z isn't installed (the caller gates the menu on canMakeSevenZip).
    public static func compress7z(_ urls: [URL], to destination: URL, excludeGit: Bool = false) async throws {
        guard let seven = sevenZipTool else { throw ArchiveError.unsupported("7z") }
        guard let parent = urls.first?.deletingLastPathComponent() else { throw ArchiveError.nothingToCompress }
        let names = urls.map(\.lastPathComponent)
        guard !names.isEmpty else { throw ArchiveError.nothingToCompress }
        var args = ["a", "-t7z", "-bd", destination.path] + names
        args += ["-xr!.DS_Store", "-xr!__MACOSX"]
        if excludeGit { args += ["-xr!.git"] }
        let (_, status, err) = try await RemoteRunner.run(seven, args, cwd: parent)
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
        case .unar:
            guard let unar = unarTool else { throw ArchiveError.unsupported(archive.lastPathComponent) }
            // -no-directory extracts the contents straight into `directory` (matching
            // tar/ditto) instead of an enclosing folder named after the archive.
            result = try await RemoteRunner.run(
                unar,
                [
                    "-quiet", "-force-overwrite", "-no-directory", "-output-directory", directory.path,
                    archive.path,
                ])
        }
        guard result.1 == 0 else { throw ArchiveError.tool(code: result.1, message: result.2) }
    }

    /// List the entry paths inside `archive` (read-only browse): bsdtar reads zip and the
    /// tar family; `lsar` reads rar/7z. Out-of-process, like the rest.
    public static func list(_ archive: URL) async throws -> [String] {
        guard let kind = kind(of: archive) else { throw ArchiveError.unsupported(archive.lastPathComponent) }
        if kind == .unar {
            guard let lsar = lsarTool else { throw ArchiveError.unsupported(archive.lastPathComponent) }
            let (data, status, err) = try await RemoteRunner.run(lsar, [archive.path])
            guard status == 0 else { throw ArchiveError.tool(code: status, message: err) }
            // lsar prints a "<name>: <Format>" header line first; drop it.
            let header = "\(archive.lastPathComponent):"
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map(String.init).filter { !$0.isEmpty && !$0.hasPrefix(header) }
        }
        let (data, status, err) = try await RemoteRunner.run("/usr/bin/tar", ["-tf", archive.path])
        guard status == 0 else { throw ArchiveError.tool(code: status, message: err) }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map(String.init).filter { !$0.isEmpty }
    }

    /// A cheap fingerprint of a folder's contents (relative path -> size+mtime), to
    /// detect whether an extracted archive mount changed and needs writing back.
    public static func snapshot(of directory: URL) -> [String: String] {
        let root = directory.standardizedFileURL.path
        let flat = FlatEnumerator.entries(of: directory, includingHidden: true, includeFolders: true)
        var map: [String: String] = [:]
        for entry in flat.entries {
            guard let location = entry.location else { continue }
            let full = (location as NSString).appendingPathComponent(entry.name)
            guard full.hasPrefix(root) else { continue }
            let rel = String(full.dropFirst(root.count))
            map[rel] = entry.isDirectory ? "dir" : "\(entry.size)|\(entry.modificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return map
    }

    /// `tar` create flags for an archive name's compression (nil if not a tar family).
    private static func tarCreateFlags(_ lowerName: String) -> [String]? {
        if lowerName.hasSuffix(".tar") { return ["-c"] }
        if lowerName.hasSuffix(".tar.gz") || lowerName.hasSuffix(".tgz") { return ["-c", "-z"] }
        if lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tbz") || lowerName.hasSuffix(".tbz2") {
            return ["-c", "-j"]
        }
        if lowerName.hasSuffix(".tar.xz") || lowerName.hasSuffix(".txz") { return ["-c", "-J"] }
        if lowerName.hasSuffix(".tar.zst") { return ["-c", "--zstd"] }
        return nil
    }

    /// Repack `directory`'s contents back into `archive`, preserving its format, by
    /// writing a sibling temp file and atomically replacing the original (so a failed
    /// repack never corrupts it). Out-of-process via zip/tar.
    public static func repack(from directory: URL, into archive: URL) async throws {
        let lower = archive.lastPathComponent.lowercased()
        let tmp = archive.deletingLastPathComponent()
            .appendingPathComponent(".pathem-repack-\(UUID().uuidString)-\(archive.lastPathComponent)")
        let result: (Data, Int32, String)
        if lower.hasSuffix(".zip") {
            result = try await RemoteRunner.run("/usr/bin/zip", ["-r", "-X", "-q", tmp.path, "."], cwd: directory)
        } else if let flags = tarCreateFlags(lower) {
            result = try await RemoteRunner.run("/usr/bin/tar", flags + ["-f", tmp.path, "-C", directory.path, "."])
        } else {
            throw ArchiveError.unsupported(archive.lastPathComponent)
        }
        guard result.1 == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ArchiveError.tool(code: result.1, message: result.2)
        }
        _ = try FileManager.default.replaceItemAt(archive, withItemAt: tmp)
    }

    /// Derive the archive's root-level entries from its full entry paths (pure, tested).
    /// A name that appears as a parent of any path is a folder.
    public static func topLevel(_ paths: [String]) -> [(name: String, isDirectory: Bool)] {
        var isDir: [String: Bool] = [:]
        var order: [String] = []
        for raw in paths {
            let path = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let first = segments.first else { continue }
            if isDir[first] == nil { order.append(first) }
            isDir[first] = (isDir[first] ?? false) || segments.count > 1 || path.hasSuffix("/")
        }
        return order.map { ($0, isDir[$0] ?? false) }
    }
}
