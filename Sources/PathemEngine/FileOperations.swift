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
        /// If a Replace conflict trashed an existing item at `destination`, where it
        /// landed in the Trash, so undo can restore the overwritten file.
        public let replacedOriginalTrashed: URL?
        public init(action: Action, source: URL, destination: URL, replacedOriginalTrashed: URL? = nil) {
            self.action = action
            self.source = source
            self.destination = destination
            self.replacedOriginalTrashed = replacedOriginalTrashed
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
        trash(urls: names.map { directory.appendingPathComponent($0) })
    }

    /// Move the given file URLs to the Trash (they may span folders, e.g. a
    /// smart-result selection). Returns the trashed items (for undo) and failures.
    public static func trash(urls: [URL]) -> (trashed: [Trashed], failures: [Failure]) {
        let fm = FileManager.default
        var trashed: [Trashed] = []
        var failures: [Failure] = []
        for source in urls {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: source, resultingItemURL: &resulting)
                if let landed = resulting as URL? {
                    trashed.append(Trashed(original: source, trashed: landed))
                }
            } catch {
                failures.append(Failure(name: source.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return (trashed, failures)
    }

    /// Restore trashed items to their original locations (the undo of `trash`). If
    /// the original location was reoccupied, restore under a non-colliding name and
    /// report it, so the file comes back instead of the undo silently failing.
    public static func untrash(_ items: [Trashed]) -> [Failure] {
        let fm = FileManager.default
        var failures: [Failure] = []
        for item in items {
            let destination = fm.fileExists(atPath: item.original.path)
                ? uniqueDestination(item.original) : item.original
            do {
                try fm.moveItem(at: item.trashed, to: destination)
                if destination != item.original {
                    failures.append(
                        Failure(
                            name: item.original.lastPathComponent,
                            reason:
                                "the original location was taken; restored as \"\(destination.lastPathComponent)\""))
                }
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
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip,
        shouldCancel: () -> Bool = { false }, progress: (Int) -> Void = { _ in }
    ) -> Outcome {
        apply(
            urls, into: destination, action: .copied, onConflict: onConflict,
            shouldCancel: shouldCancel, progress: progress
        ) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
    }

    @discardableResult
    public static func move(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip,
        shouldCancel: () -> Bool = { false }, progress: (Int) -> Void = { _ in }
    ) -> Outcome {
        apply(
            urls, into: destination, action: .moved, onConflict: onConflict,
            shouldCancel: shouldCancel, progress: progress
        ) {
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
                // Restore a file that a Replace conflict overwrote, so undo doesn't
                // leave it stranded in the Trash (and report failure if it can't).
                if let trashed = op.replacedOriginalTrashed {
                    do {
                        try fm.moveItem(at: trashed, to: op.destination)
                    } catch {
                        outcome.failures.append(
                            Failure(
                                name: op.destination.lastPathComponent,
                                reason: "couldn't restore the replaced file: \(error.localizedDescription)"))
                    }
                }
                outcome.performed.append(op)
            } catch {
                outcome.failures.append(
                    Failure(name: op.destination.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    /// Re-apply performed operations (the redo of `undo`): moves and copies go
    /// from source to their recorded destination again.
    @discardableResult
    public static func redo(_ performed: [Performed]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for op in performed {
            do {
                switch op.action {
                case .moved: try fm.moveItem(at: op.source, to: op.destination)
                case .copied: try fm.copyItem(at: op.source, to: op.destination)
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
        shouldCancel: () -> Bool, progress: (Int) -> Void,
        _ op: (URL, URL) throws -> Void
    ) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for (index, from) in sources.enumerated() {
            if shouldCancel() { break }  // stop; items already done remain in `performed`
            let name = from.lastPathComponent
            var to = destination.appendingPathComponent(name)
            var replacedTrash: URL?  // where a Replace put the overwritten file (for undo)
            do {
                // Never act on the source onto itself: a no-op self-transfer via a
                // different spelling, a symlink, or letter case on a case-insensitive
                // volume would otherwise trash the source under .replace. This is the
                // backstop for every caller (drag-drop, transfer commands, undo/redo).
                if Self.isSameItem(from, to) {
                    outcome.skipped.append(name)
                    continue
                }
                if fm.fileExists(atPath: to.path) {
                    switch onConflict {
                    case .skip:
                        outcome.skipped.append(name)
                        continue
                    case .replace:
                        var landed: NSURL?
                        try fm.trashItem(at: to, resultingItemURL: &landed)
                        replacedTrash = landed as URL?  // remember it so undo can restore it
                    case .keepBoth:
                        to = uniqueDestination(to)
                    }
                }
                try op(from, to)
                outcome.performed.append(
                    Performed(
                        action: action, source: from, destination: to, replacedOriginalTrashed: replacedTrash))
            } catch {
                outcome.failures.append(Failure(name: name, reason: error.localizedDescription))
            }
            progress(index + 1)
        }
        return outcome
    }

    /// Whether two URLs refer to the same on-disk item. Prefers the file's
    /// resource identifier (authoritative across symlinks and case); falls back
    /// to a symlink-resolved, case-insensitive path compare when `to` does not
    /// exist yet.
    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let idA = idA as? NSObject, let idB = idB as? NSObject { return idA.isEqual(idB) }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            .compare(b.resolvingSymlinksInPath().standardizedFileURL.path, options: .caseInsensitive)
            == .orderedSame
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
