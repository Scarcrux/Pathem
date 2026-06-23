import Foundation

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

    // MARK: Query builders (pure, testable)

    static func tagQuery(_ tag: String) -> String {
        "kMDItemUserTags == \"\(escape(tag))\"c"  // c = case-insensitive
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

    private static func run(query: String, scope: URL?, limit: Int) async -> [URL] {
        let mdfind = "/usr/bin/mdfind"
        guard FileManager.default.isExecutableFile(atPath: mdfind) else { return [] }
        var args = ["-0"]  // NUL-separate paths so newlines in names don't split a result
        if let scope { args += ["-onlyin", scope.path] }
        args.append(query)
        guard let (data, status, _) = try? await RemoteRunner.run(mdfind, args), status == 0 else { return [] }
        let paths = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)
        return paths.prefix(limit).map { URL(fileURLWithPath: String($0)) }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
