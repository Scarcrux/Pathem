import Foundation

/// Two-way (bidirectional) folder sync, built on FolderCompare. Additive and safe: a
/// file present on only one side is copied to the other; a file that differs on both
/// sides is resolved by policy (newer wins by default). It never deletes, so there is
/// no risk of losing data without a tracked baseline. The plan is pure and tested;
/// `execute` performs the copies.
public enum FolderSync {
    public enum Conflict: String, Sendable, CaseIterable {
        case newerWins, leftWins, rightWins, skip
    }

    public enum Direction: Sendable, Equatable { case toRight, toLeft }

    public struct Action: Sendable, Equatable {
        public let relativePath: String
        /// nil means an unresolved conflict (e.g. equal timestamps under newerWins, or
        /// the "skip" policy): it is reported but not copied.
        public let direction: Direction?
        public let wasConflict: Bool  // both sides had the file and it differed
    }

    public struct Result: Sendable, Equatable {
        public var copiedToRight = 0
        public var copiedToLeft = 0
        public var conflictsSkipped = 0
        public var failures: [String] = []
        public init() {}
    }

    /// Compute the copy actions to make `left` and `right` match (additively).
    public static func plan(
        left: URL, right: URL, conflict: Conflict = .newerWins, byContent: Bool = false,
        maxItems: Int = 200_000
    ) -> [Action] {
        let leftFiles = FolderCompare.index(of: left, maxItems: maxItems)
        let rightFiles = FolderCompare.index(of: right, maxItems: maxItems)
        var actions: [Action] = []
        for (rel, lEntry) in leftFiles {
            guard let rEntry = rightFiles[rel] else {
                actions.append(Action(relativePath: rel, direction: .toRight, wasConflict: false))
                continue
            }
            guard differs(rel, lEntry, rEntry, left: left, right: right, byContent: byContent) else {
                continue  // identical
            }
            actions.append(
                Action(
                    relativePath: rel, direction: resolve(conflict, left: lEntry, right: rEntry),
                    wasConflict: true))
        }
        for (rel, _) in rightFiles where leftFiles[rel] == nil {
            actions.append(Action(relativePath: rel, direction: .toLeft, wasConflict: false))
        }
        return actions.sorted { $0.relativePath < $1.relativePath }
    }

    @discardableResult
    public static func execute(_ actions: [Action], left: URL, right: URL) -> Result {
        let left = left.standardizedFileURL
        let right = right.standardizedFileURL
        var result = Result()
        for action in actions {
            guard let direction = action.direction else {
                result.conflictsSkipped += 1  // unresolved conflict: leave both sides as-is
                continue
            }
            switch direction {
            case .toRight:
                if FolderCompare.copy(rel: action.relativePath, from: left, to: right) {
                    result.copiedToRight += 1
                } else {
                    result.failures.append(action.relativePath)
                }
            case .toLeft:
                if FolderCompare.copy(rel: action.relativePath, from: right, to: left) {
                    result.copiedToLeft += 1
                } else {
                    result.failures.append(action.relativePath)
                }
            }
        }
        return result
    }

    // MARK: Helpers

    private static func differs(
        _ rel: String, _ l: FileEntry, _ r: FileEntry, left: URL, right: URL, byContent: Bool
    ) -> Bool {
        if l.size != r.size { return true }
        if byContent {
            return (try? FileHasher.hash(left.appendingPathComponent(rel)))
                != (try? FileHasher.hash(right.appendingPathComponent(rel)))
        }
        return l.modificationDate != r.modificationDate
    }

    /// The winning direction for a differing pair, or nil when it can't be decided
    /// (newer-wins with equal timestamps, or the skip policy).
    private static func resolve(_ policy: Conflict, left: FileEntry, right: FileEntry) -> Direction? {
        switch policy {
        case .leftWins: return .toRight
        case .rightWins: return .toLeft
        case .skip: return nil
        case .newerWins:
            let l = left.modificationDate ?? .distantPast
            let r = right.modificationDate ?? .distantPast
            if l > r { return .toRight }
            if r > l { return .toLeft }
            return nil  // same timestamp: a real conflict
        }
    }
}
