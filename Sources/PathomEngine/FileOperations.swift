import Foundation

/// Bulk file operations behind the dual-pane copy/move actions.
///
/// MVP safety posture (DESIGN.md §6.5): operations REFUSE to overwrite an
/// existing destination (FileManager throws) rather than clobbering data; each
/// item is attempted independently and failures are returned, not thrown. A
/// full conflict-resolution policy (overwrite / keep-both / skip) and an
/// app-owned undo stack are a later milestone.
public enum FileOperations {
    public struct Failure: Error, Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    /// Copy `names` from `source` into `destination`. Returns the items that
    /// failed (e.g. a name that already exists at the destination).
    @discardableResult
    public static func copy(_ names: [String], from source: URL, to destination: URL) -> [Failure] {
        apply(names, from: source, to: destination) { from, to in
            try FileManager.default.copyItem(at: from, to: to)
        }
    }

    /// Move `names` from `source` into `destination`. Returns the items that
    /// failed.
    @discardableResult
    public static func move(_ names: [String], from source: URL, to destination: URL) -> [Failure] {
        apply(names, from: source, to: destination) { from, to in
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    private static func apply(
        _ names: [String], from source: URL, to destination: URL,
        _ op: (URL, URL) throws -> Void
    ) -> [Failure] {
        var failures: [Failure] = []
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: to.path) {
                failures.append(Failure(name: name, reason: "already exists at destination"))
                continue
            }
            do {
                try op(from, to)
            } catch {
                failures.append(Failure(name: name, reason: error.localizedDescription))
            }
        }
        return failures
    }
}
