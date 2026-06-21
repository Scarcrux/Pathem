import Foundation

/// Bulk file operations behind the dual-pane copy/move actions.
///
/// Each item is attempted independently. When a name already exists at the
/// destination the caller picks a `ConflictResolution`: skip it, replace it
/// (the existing item goes to the Trash, so it is recoverable), or keep both
/// (the new item is renamed "x copy"). Every operation records what it did so
/// the UI can offer undo.
public enum FileOperations {
    public struct Failure: Error, Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    /// What to do when a name already exists at the destination.
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

    /// The names that already exist at `destination`. A caller can prompt about
    /// these before choosing a resolution.
    public static func conflicts(_ names: [String], from source: URL, to destination: URL) -> [String]
    {
        names.filter {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
        }
    }

    @discardableResult
    public static func copy(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        apply(names, from: source, to: destination, action: .copied, onConflict: onConflict) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
    }

    @discardableResult
    public static func move(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        apply(names, from: source, to: destination, action: .moved, onConflict: onConflict) {
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

    private static func apply(
        _ names: [String], from source: URL, to destination: URL,
        action: Action, onConflict: ConflictResolution,
        _ op: (URL, URL) throws -> Void
    ) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for name in names {
            let from = source.appendingPathComponent(name)
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
