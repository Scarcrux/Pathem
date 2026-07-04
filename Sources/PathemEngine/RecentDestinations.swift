import Foundation

/// A most-recent-first list of folders the user has copied or moved files into, so "Copy
/// To…" / "Move To…" can offer them again without re-picking. Pure list algebra; the app
/// persists the paths and turns each into a command. Deliberately small and deduplicated.
public enum RecentDestinations {
    public static let limit = 10

    /// Return `list` with `path` promoted to the front: deduplicated (a repeat destination
    /// moves up rather than piling up) and capped at `limit`, newest first.
    public static func recording(_ path: String, into list: [String]) -> [String] {
        guard !path.isEmpty else { return list }
        var out = list.filter { $0 != path }
        out.insert(path, at: 0)
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }
}
