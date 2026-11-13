import Foundation

/// Which folders the automatic "calculate folder sizes" walk leaves alone. Caches, temporary
/// folders and build output are large, churn constantly and are rarely what the user is
/// asking about, so sizing them on every visit burns CPU for a number nobody reads (Finder
/// does exactly that). The size stays one click away: the row says why it was skipped.
///
/// One classifier, built from the lists Cleanup already uses (`StorageScan` and
/// `ReclaimCatalog`), so the two features cannot drift apart.
public enum FolderSizeSkip {
    public enum Reason: String, Sendable, Equatable {
        case cache, temporary, regenerable, excluded
    }

    /// System temporary roots. A folder that is one of these, or inside one, is temporary.
    public static let temporaryRoots = [
        "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders",
        "/private/var/folders",
    ]

    /// Split the user's "also skip" text (commas or new lines) into rules. A rule with a
    /// slash is a path (`~` allowed) covering that folder and everything inside it; a rule
    /// without one is a folder name matched anywhere.
    public static func rules(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Why the folder at `path` is not sized automatically, or nil when it is.
    public static func reason(for path: String, home: String, userRules: [String] = [])
        -> Reason?
    {
        let path = clean(path)
        let home = clean(home)
        let name = (path as NSString).lastPathComponent
        for rule in userRules {
            if rule.contains("/") {
                let expanded = clean(rule.hasPrefix("~") ? home + rule.dropFirst() : rule)
                if isAt(path, orInside: expanded) { return .excluded }
            } else if rule == name {
                return .excluded
            }
        }
        if temporaryRoots.contains(where: { isAt(path, orInside: $0) }) { return .temporary }
        if StorageScan.cacheDirectories.contains(name) { return .cache }
        if ReclaimCatalog.cacheRoots.contains(where: { isAt(path, orInside: home + "/" + $0) }) {
            return .cache
        }
        // Catalogued places that rebuild or re-download (DerivedData, ~/.npm, model stores).
        // "Review" places such as Downloads are the user's own files and are sized normally.
        if ReclaimCatalog.places.contains(where: {
            $0.consequence != .review && isAt(path, orInside: home + "/" + $0.relativePath)
        }) {
            return .cache
        }
        if StorageScan.junkDirectories.contains(name) { return .regenerable }
        return nil
    }

    private static func clean(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isAt(_ path: String, orInside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
