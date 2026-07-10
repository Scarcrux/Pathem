import Foundation

/// Compress and extract archives by shelling OUT OF PROCESS to the BSD-licensed
/// command-line tools that ship with macOS (`/usr/bin/zip`, `/usr/bin/tar`,
/// `/usr/bin/ditto`) — never a GPL library, and untrusted-archive parsing stays
/// out of the Full-Disk-Access process. macOS's `tar` is bsdtar on libarchive, which
/// reads (and writes) 7-Zip and reads RAR natively, so no third-party tools are needed.
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

    /// Whether we can write `url`'s contents back into the same format. libarchive can
    /// create zip, the tar family, and 7-Zip, but not RAR (proprietary, read-only).
    public static func canRepack(_ url: URL) -> Bool {
        guard canExtract(url) else { return false }
        return !url.lastPathComponent.lowercased().hasSuffix(".rar")
    }

    private enum Kind { case zip, libarchive }

    private static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        // bsdtar (libarchive) reads the tar family plus 7-Zip and RAR (incl. RAR5).
        for suffix in [
            ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst",
            ".7z", ".rar",
        ] where name.hasSuffix(suffix) {
            return .libarchive
        }
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

    /// Zip items that may live in *different* folders (e.g. a drag from another pane onto a file).
    /// `compress` assumes one shared parent and would silently miss the rest, so when the items span
    /// folders, stage them into a temp directory first -- hardlinked where possible (instant, no extra
    /// bytes), copied for directories or cross-volume items -- then archive that into a clean flat zip.
    public static func compressItems(_ urls: [URL], to destination: URL, excludeGit: Bool = false) async throws {
        guard !urls.isEmpty else { throw ArchiveError.nothingToCompress }
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1 { return try await compress(urls, to: destination, excludeGit: excludeGit) }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("pathem-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var used = Set<String>()
        var staged: [URL] = []
        for url in urls {
            var name = url.lastPathComponent
            var n = 2
            while used.contains(name) {  // two items with the same name from different folders
                let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
                name = "\(url.deletingPathExtension().lastPathComponent) \(n)\(ext)"
                n += 1
            }
            used.insert(name)
            let dest = staging.appendingPathComponent(name)
            do { try fm.linkItem(at: url, to: dest) } catch { try fm.copyItem(at: url, to: dest) }
            staged.append(dest)
        }
        try await compress(staged, to: destination, excludeGit: excludeGit)
    }

    /// Create a 7-Zip archive from items sharing a parent. bsdtar (libarchive) writes 7z
    /// natively from the `.7z` extension, so no third-party tool is needed.
    public static func compress7z(_ urls: [URL], to destination: URL, excludeGit: Bool = false) async throws {
        guard let parent = urls.first?.deletingLastPathComponent() else { throw ArchiveError.nothingToCompress }
        let names = urls.map(\.lastPathComponent)
        guard !names.isEmpty else { throw ArchiveError.nothingToCompress }
        var args = ["-a", "-c", "-f", destination.path, "--exclude", ".DS_Store", "--exclude", "__MACOSX"]
        if excludeGit { args += ["--exclude", ".git"] }
        args += ["-C", parent.path] + names
        let (_, status, err) = try await RemoteRunner.run("/usr/bin/tar", args)
        guard status == 0 else { throw ArchiveError.tool(code: status, message: err) }
    }

    /// Extract `archive` into `directory` (zip via ditto; everything else via bsdtar,
    /// which auto-detects tar-family compression and reads 7-Zip and RAR).
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
        case .libarchive:
            result = try await RemoteRunner.run(
                "/usr/bin/tar", ["-x", "-f", archive.path, "-C", directory.path])
        }
        guard result.1 == 0 else { throw ArchiveError.tool(code: result.1, message: result.2) }
    }

    /// List the entry paths inside `archive` (read-only browse) via bsdtar, which reads
    /// zip, the tar family, 7-Zip, and RAR. Out-of-process, like the rest.
    public static func list(_ archive: URL) async throws -> [String] {
        guard canExtract(archive) else { throw ArchiveError.unsupported(archive.lastPathComponent) }
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
    /// repack never corrupts it). Out-of-process via zip/tar (tar also writes 7-Zip).
    /// RAR is read-only (libarchive can't write it); callers gate on `canRepack`.
    public static func repack(from directory: URL, into archive: URL) async throws {
        let lower = archive.lastPathComponent.lowercased()
        let tmp = archive.deletingLastPathComponent()
            .appendingPathComponent(".pathem-repack-\(UUID().uuidString)-\(archive.lastPathComponent)")
        let result: (Data, Int32, String)
        if lower.hasSuffix(".zip") {
            result = try await RemoteRunner.run("/usr/bin/zip", ["-r", "-X", "-q", tmp.path, "."], cwd: directory)
        } else if let flags = tarCreateFlags(lower) {
            result = try await RemoteRunner.run("/usr/bin/tar", flags + ["-f", tmp.path, "-C", directory.path, "."])
        } else if lower.hasSuffix(".7z") {
            // -a picks the 7z writer from the temp file's .7z suffix.
            result = try await RemoteRunner.run("/usr/bin/tar", ["-a", "-c", "-f", tmp.path, "-C", directory.path, "."])
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
