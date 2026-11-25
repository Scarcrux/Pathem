import Foundation

/// The folder tree's roots and its persisted state: which folders the user pinned and which
/// nodes were expanded. Pure value logic (no AppKit, no disk), so it is tested directly.
public struct FolderTreeState: Codable, Sendable, Equatable {
    /// Pinned folder paths, in the order the user pinned them.
    public var pinned: [String]
    /// Expanded folder paths, oldest first. Capped at `maxExpanded`.
    public var expanded: [String]

    public static let maxPinned = 100
    public static let maxExpanded = 200

    public init(pinned: [String] = [], expanded: [String] = []) {
        self.pinned = pinned
        self.expanded = expanded
    }

    /// Old configs have neither key; a corrupt or oversized list is trimmed, never fatal.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        let expanded = try c.decodeIfPresent([String].self, forKey: .expanded) ?? []
        self.pinned = Self.unique(pinned).suffix(Self.maxPinned).map { $0 }
        self.expanded = Self.unique(expanded).suffix(Self.maxExpanded).map { $0 }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    public func isPinned(_ url: URL) -> Bool { pinned.contains(Self.key(url)) }

    /// Pin a folder. Returns false when it was already pinned, or is the volume root (which is
    /// always a root anyway).
    @discardableResult
    public mutating func pin(_ url: URL) -> Bool {
        let path = Self.key(url)
        guard path != "/", !pinned.contains(path) else { return false }
        pinned.append(path)
        if pinned.count > Self.maxPinned { pinned.removeFirst(pinned.count - Self.maxPinned) }
        return true
    }

    @discardableResult
    public mutating func unpin(_ url: URL) -> Bool {
        let path = Self.key(url)
        guard let index = pinned.firstIndex(of: path) else { return false }
        pinned.remove(at: index)
        return true
    }

    public func isExpanded(_ url: URL) -> Bool { expanded.contains(Self.key(url)) }

    /// Record an expand or collapse. The most recently expanded folders win when over the cap.
    public mutating func setExpanded(_ url: URL, _ isExpanded: Bool) {
        let path = Self.key(url)
        expanded.removeAll { $0 == path }
        guard isExpanded else { return }
        expanded.append(path)
        if expanded.count > Self.maxExpanded {
            expanded.removeFirst(expanded.count - Self.maxExpanded)
        }
    }

    /// Expanded folders shallowest first, so a restore opens parents before children.
    public var expandedShallowFirst: [URL] {
        expanded.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
    }
}

extension FolderTree {
    public struct Root: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case home, volume, pinned }
        public let url: URL
        public let name: String
        public let kind: Kind
        public init(url: URL, name: String, kind: Kind) {
            self.url = url.standardizedFileURL
            self.name = name
            self.kind = kind
        }
    }

    /// The tree's roots in display order: Home, each mounted volume, then the pinned folders.
    /// A volume that is the home folder, or a pinned folder that duplicates another root, is
    /// dropped, so no folder is a root twice.
    public static func roots(
        home: URL, homeName: String, volumes: [(url: URL, name: String)], pinned: [URL],
        pinnedName: (URL) -> String = { $0.lastPathComponent }
    ) -> [Root] {
        var roots = [Root(url: home, name: homeName, kind: .home)]
        var seen: Set<String> = [roots[0].url.path]
        for volume in volumes {
            let root = Root(url: volume.url, name: volume.name, kind: .volume)
            if seen.insert(root.url.path).inserted { roots.append(root) }
        }
        for url in pinned {
            let root = Root(url: url, name: pinnedName(url), kind: .pinned)
            if seen.insert(root.url.path).inserted { roots.append(root) }
        }
        return roots
    }

    /// The index of the root that should show `target`: the deepest Home or volume root that
    /// contains it. Pinned folders are shortcuts, so they only show a location that no Home or
    /// volume root contains. Nil when no root contains the target.
    public static func rootIndex(containing target: URL, in roots: [Root]) -> Int? {
        var best: (index: Int, depth: Int)?
        for pass in [false, true] {
            for (index, root) in roots.enumerated()
            where (root.kind == .pinned) == pass
                && revealChain(root: root.url, target: target) != nil
            {
                let depth = root.url.pathComponents.count
                if best == nil || depth > best!.depth { best = (index, depth) }
            }
            if best != nil { break }
        }
        return best?.index
    }
}
