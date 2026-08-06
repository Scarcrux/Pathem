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

    /// Recently changed (or, when `opened`, recently used) files, most recent first. mdfind can't
    /// sort, so we sort the matches by the relevant date and cap. The sort also decides WHICH
    /// `limit` files survive, so it must use the same date the query filtered on.
    public static func recentFiles(
        scope: URL? = nil, days: Int = 30, limit: Int = 200, opened: Bool = false
    ) async -> [URL] {
        let urls = await run(query: recentQuery(days: days, opened: opened), scope: scope, limit: 5000)
        let sorted = urls.sorted { recencyDate($0, opened: opened) > recencyDate($1, opened: opened) }
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

    /// Files touched within `days`. `opened` selects "recently used" (Finder's Recents) instead of
    /// the default "recently changed on disk".
    static func recentQuery(days: Int, opened: Bool = false) -> String {
        let seconds = max(1, days) * 86_400
        let attribute = opened ? "kMDItemLastUsedDate" : "kMDItemFSContentChangeDate"
        return "\(attribute) >= $time.now(-\(seconds))"
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

    /// Whether Spotlight indexing is on for the volume that actually holds the user's files. Smart
    /// folders and search all depend on `mdfind`, which returns nothing when indexing is disabled --
    /// so an empty result plus this being false means "Spotlight is off", not "no matches".
    ///
    /// It must check the DATA volume, not `/`. On modern macOS `/` is the sealed, read-only system
    /// volume and reports "Indexing enabled" even when the user's own Data volume is disabled, so
    /// asking only about `/` made a dead index look healthy: smart folders came back empty and we
    /// told the user nothing. Checks the data volume first, then `/`; assumes enabled if it can't
    /// tell either way. Runs off-main.
    public static func indexingEnabled() async -> Bool {
        let mdutil = "/usr/bin/mdutil"
        guard FileManager.default.isExecutableFile(atPath: mdutil) else { return true }
        for volume in ["/System/Volumes/Data", "/"] {
            guard let (data, _, _) = try? await RemoteRunner.run(mdutil, ["-s", volume]) else { continue }
            let output = String(decoding: data, as: UTF8.self)
            // "Indexing enabled." when on; "Indexing disabled." when off. Anything else -> keep looking.
            if output.localizedCaseInsensitiveContains("Indexing disabled") { return false }
        }
        return true
    }

    /// The date a "recent" result is ranked by: last-access time for the `opened` basis (the closest
    /// URL-resource proxy for "last used"), content-modification time otherwise.
    private static func recencyDate(_ url: URL, opened: Bool) -> Date {
        let key: URLResourceKey = opened ? .contentAccessDateKey : .contentModificationDateKey
        let values = try? url.resourceValues(forKeys: [key])
        return (opened ? values?.contentAccessDate : values?.contentModificationDate) ?? .distantPast
    }
}
