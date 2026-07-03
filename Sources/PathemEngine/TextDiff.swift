import Foundation

/// A line-level diff of two texts via the classic LCS alignment, for a side-by-side file
/// comparison. Pure Foundation, unit-tested. Capped at `maxLines` per side (the LCS table
/// is O(n*m)); beyond that it compares the first `maxLines` and flags the result truncated.
public enum TextDiff {
    public enum Kind: Sendable, Equatable { case equal, insert, delete }

    /// One aligned output row: an equal pair, a left-only deletion, or a right-only insertion.
    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let left: String?
        public let right: String?
        public let leftNumber: Int?
        public let rightNumber: Int?
    }

    public struct Result: Sendable, Equatable {
        public var lines: [Line] = []
        public var added = 0
        public var removed = 0
        public var truncated = false
    }

    public static func diff(_ a: String, _ b: String, maxLines: Int = 4000) -> Result {
        var aLines = a.components(separatedBy: "\n")
        var bLines = b.components(separatedBy: "\n")
        var result = Result()
        if aLines.count > maxLines { aLines = Array(aLines.prefix(maxLines)); result.truncated = true }
        if bLines.count > maxLines { bLines = Array(bLines.prefix(maxLines)); result.truncated = true }
        let n = aLines.count
        let m = bLines.count

        // Flat LCS-length table, filled bottom-up so a backtrack yields a stable alignment.
        var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[at(i, j)] =
                        aLines[i] == bLines[j]
                        ? dp[at(i + 1, j + 1)] + 1
                        : max(dp[at(i + 1, j)], dp[at(i, j + 1)])
                }
            }
        }

        var i = 0, j = 0, la = 1, lb = 1
        while i < n && j < m {
            if aLines[i] == bLines[j] {
                result.lines.append(.init(kind: .equal, left: aLines[i], right: bLines[j], leftNumber: la, rightNumber: lb))
                i += 1; j += 1; la += 1; lb += 1
            } else if dp[at(i + 1, j)] >= dp[at(i, j + 1)] {
                result.lines.append(.init(kind: .delete, left: aLines[i], right: nil, leftNumber: la, rightNumber: nil))
                i += 1; la += 1; result.removed += 1
            } else {
                result.lines.append(.init(kind: .insert, left: nil, right: bLines[j], leftNumber: nil, rightNumber: lb))
                j += 1; lb += 1; result.added += 1
            }
        }
        while i < n {
            result.lines.append(.init(kind: .delete, left: aLines[i], right: nil, leftNumber: la, rightNumber: nil))
            i += 1; la += 1; result.removed += 1
        }
        while j < m {
            result.lines.append(.init(kind: .insert, left: nil, right: bLines[j], leftNumber: nil, rightNumber: lb))
            j += 1; lb += 1; result.added += 1
        }
        return result
    }
}
