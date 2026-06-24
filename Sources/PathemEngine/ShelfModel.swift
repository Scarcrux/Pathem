import Foundation

/// The "Stash Shelf" / drop-stack collection: an ordered, de-duplicated set of file
/// URLs gathered from any folder, pane, or tab, to be acted on together (copy,
/// move, trash, share). Pure value logic so the collection behavior is unit-tested
/// without any UI; the controller renders it and the existing FileOperations carry
/// out the actions.
public struct ShelfModel: Sendable, Equatable {
    public private(set) var items: [URL]

    public init(items: [URL] = []) {
        self.items = items.map { $0.standardizedFileURL }.reduced()
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Append new URLs, keeping insertion order and ignoring ones already present.
    /// Returns true if anything was actually added.
    @discardableResult
    public mutating func add(_ urls: [URL]) -> Bool {
        let before = items.count
        var seen = Set(items)
        for url in urls {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized).inserted { items.append(standardized) }
        }
        return items.count != before
    }

    public mutating func remove(_ url: URL) {
        let standardized = url.standardizedFileURL
        items.removeAll { $0 == standardized }
    }

    public mutating func removeAll() { items.removeAll() }

    public func contains(_ url: URL) -> Bool { items.contains(url.standardizedFileURL) }
}

extension Array where Element == URL {
    /// Order-preserving de-duplication.
    fileprivate func reduced() -> [URL] {
        var seen = Set<URL>()
        return filter { seen.insert($0).inserted }
    }
}
