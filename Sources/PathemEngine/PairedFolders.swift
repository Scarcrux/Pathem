import Foundation

/// Which pane a folder change came from.
public enum PairSide: Sendable, Equatable { case left, right }

/// A left folder and the right folder it corresponds to (a project and its backup, a source tree
/// and its build output). Persisted in Preferences.
public struct FolderPair: Codable, Sendable, Equatable {
    public var left: String
    public var right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }
}

/// What following a paired folder should do after one pane moved.
public enum PairedNavigation: Sendable, Equatable {
    /// The moved pane is outside every pair that holds both panes: nothing to follow.
    case notApplicable
    /// Take the other pane to this folder.
    case follow(URL)
    /// Both panes sit in a pair but the other side has no folder at the same relative path; the
    /// other pane stays put.
    case noMatch
}

/// Pure logic for paired folders: relative-path mapping between the two sides of a pair.
public enum PairedFolders {
    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }

    /// `url`'s path below `root` as components (empty when it is `root` itself), or nil when it
    /// is not inside `root`. Compares whole components, so `/a/bc` is not inside `/a/b`.
    public static func relativePath(of url: URL, under root: URL) -> [String]? {
        let u = components(url)
        let r = components(root)
        guard u.count >= r.count, Array(u.prefix(r.count)) == r else { return nil }
        return Array(u.dropFirst(r.count))
    }

    private static func resolve(_ root: URL, _ relative: [String]) -> URL {
        relative.reduce(root.standardizedFileURL) { $0.appendingPathComponent($1) }
    }

    private static func roots(_ pair: FolderPair, side: PairSide) -> (own: URL, other: URL) {
        let left = URL(fileURLWithPath: pair.left)
        let right = URL(fileURLWithPath: pair.right)
        return side == .left ? (left, right) : (right, left)
    }

    /// The pane that did not move should follow `newFolder` (where `moved` just went) to the same
    /// relative path inside the pair, when both panes sit inside one pair. With several matching
    /// pairs the deepest one wins.
    public static func counterpart(
        pairs: [FolderPair], moved: PairSide, newFolder: URL, otherFolder: URL,
        exists: (URL) -> Bool
    ) -> PairedNavigation {
        var best: (depth: Int, target: URL)?
        for pair in pairs {
            let (own, other) = roots(pair, side: moved)
            guard let relative = relativePath(of: newFolder, under: own),
                relativePath(of: otherFolder, under: other) != nil
            else { continue }
            let depth = components(own).count + components(other).count
            if best == nil || depth > best!.depth { best = (depth, resolve(other, relative)) }
        }
        guard let best else { return .notApplicable }
        return exists(best.target) ? .follow(best.target) : .noMatch
    }

    /// One-shot "Go to Same Folder in Other Pane": the other pane's folder that matches
    /// `activeFolder`. Uses the deepest pair holding the active pane's folder; with no pair (or
    /// no such folder there), falls back to the folder of the same name in the other pane's
    /// parent. Nil when neither exists.
    public static func sameFolder(
        pairs: [FolderPair], active: PairSide, activeFolder: URL, otherFolder: URL,
        exists: (URL) -> Bool
    ) -> URL? {
        var best: (depth: Int, target: URL)?
        for pair in pairs {
            let (own, other) = roots(pair, side: active)
            guard let relative = relativePath(of: activeFolder, under: own) else { continue }
            let depth = components(own).count + components(other).count
            if best == nil || depth > best!.depth { best = (depth, resolve(other, relative)) }
        }
        if let best, exists(best.target) { return best.target }
        let sibling = otherFolder.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(activeFolder.lastPathComponent)
        return exists(sibling) ? sibling : nil
    }

    /// `pairs` plus `pair`, unless the same two folders are already paired.
    public static func adding(_ pair: FolderPair, to pairs: [FolderPair]) -> [FolderPair] {
        func key(_ p: FolderPair) -> [String] {
            [
                URL(fileURLWithPath: p.left).standardizedFileURL.path,
                URL(fileURLWithPath: p.right).standardizedFileURL.path,
            ]
        }
        guard !pairs.contains(where: { key($0) == key(pair) }) else { return pairs }
        return pairs + [pair]
    }
}
