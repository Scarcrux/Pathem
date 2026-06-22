import Foundation

/// Bulk file operations behind copy/move (between panes, and the clipboard).
///
/// Each item is attempted independently. When a name already exists at the
/// destination the caller picks a `ConflictResolution`: skip it, replace it (the
/// existing item goes to the Trash, so it is recoverable), or keep both (the new
/// item is renamed "x copy"). Every operation records what it did so the UI can
/// offer undo. Sources can be given by name within a folder, or as full URLs
/// (so a paste can pull from any location, including a Finder copy).
public enum FileOperations {
    public struct Failure: Error, Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public enum ConflictResolution: Sendable { case skip, replace, keepBoth }

    public enum Action: Sendable { case copied, moved }

    /// One item that was actually copied or moved. Enough to reverse it.
    public struct Performed: Sendable, Equatable {
        public let action: Action
        public let source: URL
        public let destination: URL
        public init(action: Action, source: URL, destination: URL) {
            self.action = action
            self.source = source
            self.destination = destination
        }
    }

    public struct Outcome: Sendable {
        public var performed: [Performed] = []
        public var skipped: [String] = []
        public var failures: [Failure] = []
        public init() {}
    }

    // MARK: Conflict detection

    public static func conflicts(_ names: [String], from source: URL, to destination: URL) -> [String]
    {
        conflicts(urls: names.map { source.appendingPathComponent($0) }, into: destination)
    }

    public static func conflicts(urls: [URL], into destination: URL) -> [String] {
        urls.compactMap { url in
            let name = url.lastPathComponent
            let exists = FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(name).path)
            return exists ? name : nil
        }
    }

    // MARK: New folder

    /// Create a new folder in `directory`, picking a unique "untitled folder"
    /// name (Finder-style) when the base name is taken. Returns the name created.
    @discardableResult
    public static func makeFolder(in directory: URL, baseName: String = "untitled folder") throws -> String {
        let fm = FileManager.default
        var name = baseName
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(baseName) \(n)"
            n += 1
        }
        try fm.createDirectory(
            at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
        return name
    }

    // MARK: Rename

    /// Rename a single item. Throws if the destination exists (no clobber) or the
    /// move fails; a no-op when the name is unchanged or empty.
    public static func rename(_ name: String, to newName: String, in directory: URL) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent(name),
            to: directory.appendingPathComponent(trimmed))
    }

    // MARK: Trash

    /// A trashed item plus where it landed, so a move-to-trash can be undone.
    public struct Trashed: Sendable, Equatable {
        public let original: URL
        public let trashed: URL
        public init(original: URL, trashed: URL) {
            self.original = original
            self.trashed = trashed
        }
    }

    /// Move `names` in `directory` to the Trash. Returns the trashed items (for
    /// undo) and any failures.
    public static func trash(_ names: [String], in directory: URL)
        -> (trashed: [Trashed], failures: [Failure])
    {
        let fm = FileManager.default
        var trashed: [Trashed] = []
        var failures: [Failure] = []
        for name in names {
            let source = directory.appendingPathComponent(name)
            var resulting: NSURL?
            do {
                try fm.trashItem(at: source, resultingItemURL: &resulting)
                if let landed = resulting as URL? {
                    trashed.append(Trashed(original: source, trashed: landed))
                }
            } catch {
                failures.append(Failure(name: name, reason: error.localizedDescription))
            }
        }
        return (trashed, failures)
    }

    /// Restore trashed items to their original locations (the undo of `trash`).
    public static func untrash(_ items: [Trashed]) -> [Failure] {
        let fm = FileManager.default
        var failures: [Failure] = []
        for item in items {
            do {
                try fm.moveItem(at: item.trashed, to: item.original)
            } catch {
                failures.append(Failure(name: item.original.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return failures
    }

    // MARK: Copy / move

    @discardableResult
    public static func copy(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        copy(urls: names.map { source.appendingPathComponent($0) }, into: destination, onConflict: onConflict)
    }

    @discardableResult
    public static func move(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        move(urls: names.map { source.appendingPathComponent($0) }, into: destination, onConflict: onConflict)
    }

    @discardableResult
    public static func copy(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip
    ) -> Outcome {
        apply(urls, into: destination, action: .copied, onConflict: onConflict) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
    }

    @discardableResult
    public static func move(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip
    ) -> Outcome {
        apply(urls, into: destination, action: .moved, onConflict: onConflict) {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    }

    /// Reverse a set of performed operations: moves go back to their source,
    /// copies go to the Trash. Used to implement undo.
    @discardableResult
    public static func undo(_ performed: [Performed]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for op in performed {
            do {
                switch op.action {
                case .moved:
                    guard !fm.fileExists(atPath: op.source.path) else {
                        outcome.failures.append(
                            Failure(
                                name: op.destination.lastPathComponent,
                                reason: "original location is occupied"))
                        continue
                    }
                    try fm.moveItem(at: op.destination, to: op.source)
                case .copied:
                    try fm.trashItem(at: op.destination, resultingItemURL: nil)
                }
                outcome.performed.append(op)
            } catch {
                outcome.failures.append(
                    Failure(name: op.destination.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: Core

    private static func apply(
        _ sources: [URL], into destination: URL,
        action: Action, onConflict: ConflictResolution,
        _ op: (URL, URL) throws -> Void
    ) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for from in sources {
            let name = from.lastPathComponent
            var to = destination.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: to.path) {
                    switch onConflict {
                    case .skip:
                        outcome.skipped.append(name)
                        continue
                    case .replace:
                        try fm.trashItem(at: to, resultingItemURL: nil)
                    case .keepBoth:
                        to = uniqueDestination(to)
                    }
                }
                try op(from, to)
                outcome.performed.append(Performed(action: action, source: from, destination: to))
            } catch {
                outcome.failures.append(Failure(name: name, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    /// A non-colliding variant like "report copy.txt", then "report copy 2.txt".
    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            return dir.appendingPathComponent(name)
        }

        var result = candidate("copy")
        var n = 2
        while fm.fileExists(atPath: result.path) {
            result = candidate("copy \(n)")
            n += 1
        }
        return result
    }
}
