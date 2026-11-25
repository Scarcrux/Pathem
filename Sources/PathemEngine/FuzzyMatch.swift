import Foundation

/// Subsequence fuzzy matching for find-as-you-type: ranking commands in the
/// palette, and filtering the current listing by name (DESIGN.md section 10,
/// Phase 3). Greedy left-to-right match (not optimal alignment, but fast and
/// what palettes use), with bonuses for prefix, word-start, and consecutive hits.
public enum FuzzyMatch {
    /// A score if every character of `query` appears in `candidate` in order
    /// (case-insensitive); higher is a better match. An empty query scores 0
    /// (matches anything). Returns nil when there is no subsequence match.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        var qi = 0
        var ci = 0
        var total = 0
        var lastMatch = -2
        while qi < q.count, ci < c.count {
            if q[qi] == c[ci] {
                var bonus = 1
                if ci == 0 {
                    bonus += 5  // matches the very start
                } else if isBoundary(c[ci - 1]) {
                    bonus += 4  // matches the start of a word
                }
                if ci == lastMatch + 1 { bonus += 3 }  // consecutive run
                total += bonus
                lastMatch = ci
                qi += 1
            }
            ci += 1
        }
        return qi == q.count ? total : nil
    }

    /// Points a keyword match loses against an equal title match, so a command
    /// found by its real title outranks one found only by an alias.
    static let keywordPenalty = 4

    /// Keep only matching items, best score first; ties preserve the original
    /// order (stable). An empty query returns the items unchanged. `keywords`
    /// supplies search aliases (for example "Preferences" for Settings): an item
    /// matches on its key or any alias, an alias scoring slightly lower than the
    /// same text in the key. The alias only affects ranking, never what is shown.
    public static func rank<T>(
        _ items: [T], query: String, key: (T) -> String,
        keywords: (T) -> [String] = { _ in [] }
    ) -> [T] {
        if query.isEmpty { return items }
        return
            items
            .enumerated()
            .compactMap { index, item -> (score: Int, index: Int, item: T)? in
                var best = score(query, key(item))
                for word in keywords(item) {
                    guard let s = score(query, word) else { continue }
                    best = max(best ?? Int.min, s - keywordPenalty)
                }
                guard let s = best else { return nil }
                return (s, index, item)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "." || ch == "_" || ch == "-" || ch == "/"
    }
}
