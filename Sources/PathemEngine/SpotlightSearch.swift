import Foundation
import os

/// Runs Spotlight (`mdfind`) queries off the main actor for smart locations that
/// span folders (Recents, tag filters). Returns matching file URLs. The query
/// builders are pure so they can be unit-tested without relying on the index.
public enum SpotlightSearch {
    /// Files whose Finder tag set contains `tag`.
    public static func taggedFiles(_ tag: String, scope: URL? = nil, limit: Int = 500) async -> [URL] {
        await run(query: tagQuery(tag), scope: scope, limit: limit)
    }

    /// Recently changed files, most recent first (mdfind can't sort, so we sort
    /// the matches by modification date and cap).
    public static func recentFiles(scope: URL? = nil, days: Int = 30, limit: Int = 200) async -> [URL] {
        let urls = await run(query: recentQuery(days: days), scope: scope, limit: 5000)
        let sorted = urls.sorted { modificationDate($0) > modificationDate($1) }
        return Array(sorted.prefix(limit))
    }

    /// Files matching a raw mdfind predicate (e.g. from a SavedSearch).
    public static func matching(_ query: String, scope: URL? = nil, limit: Int = 1000) async -> [URL] {
        guard !query.isEmpty else { return [] }
        return await run(query: query, scope: scope, limit: limit)
    }

    // MARK: Query builders (pure, testable)

    static func tagQuery(_ tag: String) -> String {
        "kMDItemUserTags == \"\(escape(tag))\"c"  // c = case-insensitive
    }

    /// An mdfind predicate matching a filename substring (case-insensitive), for instant
    /// "find files by name" search. Empty when the trimmed text is empty.
    public static func filenameQuery(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : "kMDItemFSName == \"*\(escape(trimmed))*\"c"
    }

    static func recentQuery(days: Int) -> String {
        let seconds = max(1, days) * 86_400
        return "kMDItemFSContentChangeDate >= $time.now(-\(seconds))"
    }

    /// Escape a value for an mdfind quoted string (backslash and quote).
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Runner

    private static let log = Logger(subsystem: "com.scarcrux.pathem", category: "SpotlightSearch")

    private static func run(query: String, scope: URL?, limit: Int) async -> [URL] {
        let mdfind = "/usr/bin/mdfind"
        guard FileManager.default.isExecutableFile(atPath: mdfind) else { return [] }
        var args = ["-0"]  // NUL-separate paths so newlines in names don't split a result
        if let scope { args += ["-onlyin", scope.path] }
        args.append(query)
        do {
            let (data, status, err) = try await RemoteRunner.run(mdfind, args)
            guard status == 0 else {
                // Don't fail silently to an empty folder; a non-zero mdfind is diagnosable.
                log.error("mdfind exited \(status): \(err, privacy: .public)")
                return []
            }
            let paths = String(decoding: data, as: UTF8.self).split(
                separator: "\0", omittingEmptySubsequences: true)
            return paths.prefix(limit).map { URL(fileURLWithPath: String($0)) }
        } catch {
            log.error("mdfind failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Whether Spotlight indexing is on for the boot volume. Smart folders and search all
    /// depend on `mdfind`, which returns nothing when indexing is disabled -- so an empty
    /// result plus this being false means "Spotlight is off", not "no matches". Runs
    /// `mdutil -s /` off-main; assumes enabled if it can't tell.
    public static func indexingEnabled() async -> Bool {
        let mdutil = "/usr/bin/mdutil"
        guard FileManager.default.isExecutableFile(atPath: mdutil),
            let (data, _, _) = try? await RemoteRunner.run(mdutil, ["-s", "/"])
        else { return true }
        let output = String(decoding: data, as: UTF8.self)
        // "Indexing enabled." when on; "Indexing disabled." when off. Anything else -> assume on.
        if output.localizedCaseInsensitiveContains("Indexing disabled") { return false }
        return true
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
