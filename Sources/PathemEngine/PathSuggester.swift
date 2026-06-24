import Foundation

/// Resolves a typed or pasted path (absolute or relative) and, when it does not
/// exist, fuzzy-corrects each missing component against the real directory
/// contents to suggest the closest existing path ("did you mean ...").
///
/// Pure and AppKit-free, so the resolution and correction logic is unit-tested
/// without a UI. A case-insensitive edit-distance match is the always-available
/// core; if the optional on-device `TextEmbedder` model is present, it breaks ties
/// among equally-close candidates by semantic similarity.
public enum PathSuggester {
    /// How the input was interpreted.
    public enum Kind: Sendable, Equatable { case absolute, relative }

    public struct Resolution: Sendable, Equatable {
        public let kind: Kind
        /// Where the input pointed after expansion/standardization (may not exist).
        public let requested: URL
        /// The input itself, when it exists on disk.
        public let existing: URL?
        /// The closest existing path, when `existing` is nil and one was found.
        public let suggestion: URL?
        public var exists: Bool { existing != nil }

        public init(kind: Kind, requested: URL, existing: URL?, suggestion: URL?) {
            self.kind = kind
            self.requested = requested
            self.existing = existing
            self.suggestion = suggestion
        }
    }

    /// Resolve `raw` against `base`. Absolute when it starts with "/" or "~";
    /// otherwise relative to `base`.
    public static func resolve(_ raw: String, base: URL, embedder: TextEmbedder? = nil) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let isAbsolute = expanded.hasPrefix("/") || trimmed.hasPrefix("~")
        let kind: Kind = isAbsolute ? .absolute : .relative
        let target =
            (isAbsolute
            ? URL(fileURLWithPath: expanded)
            : base.appendingPathComponent(expanded)).standardizedFileURL

        if FileManager.default.fileExists(atPath: target.path) {
            return Resolution(kind: kind, requested: target, existing: target, suggestion: nil)
        }
        return Resolution(
            kind: kind, requested: target, existing: nil,
            suggestion: suggest(for: target, embedder: embedder))
    }

    /// Walk from the filesystem root, fuzzy-correcting each missing component to the
    /// closest existing child. Returns the best existing path, or nil if no actual
    /// correction could be made.
    static func suggest(for target: URL, embedder: TextEmbedder?) -> URL? {
        let fm = FileManager.default
        let components = target.pathComponents  // ["/", "Users", ...]
        guard components.first == "/" else { return nil }
        var current = URL(fileURLWithPath: "/")
        var corrected = false
        for component in components.dropFirst() {
            let exact = current.appendingPathComponent(component)
            if fm.fileExists(atPath: exact.path) {
                current = exact  // this component is fine; descend
                continue
            }
            guard let match = bestMatch(component, in: current, embedder: embedder) else { break }
            current = current.appendingPathComponent(match)
            corrected = true
        }
        // Only offer a suggestion if a real typo was fixed and we landed on a path
        // that exists and differs from what was typed.
        guard corrected, current != target, fm.fileExists(atPath: current.path) else { return nil }
        return current.standardizedFileURL
    }

    /// The closest existing child name in `directory` to `name`: an exact
    /// case-insensitive match, else the nearest by edit distance within tolerance.
    static func bestMatch(_ name: String, in directory: URL, embedder: TextEmbedder?) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path), !entries.isEmpty else {
            return nil
        }
        if let exact = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let lowerName = name.lowercased()
        let tolerance = max(2, name.count / 3)  // allow more slack for longer names
        let candidates = entries
            .map { (name: $0, score: distance(lowerName, $0.lowercased())) }
            .filter { $0.score <= tolerance }
            .sorted { $0.score < $1.score }
        if let best = candidates.first {
            // Break a tie among equally-close names with the on-device model when present.
            if let embedder, candidates.count > 1, candidates[0].score == candidates[1].score {
                let tied = candidates.filter { $0.score == best.score }.map(\.name)
                return semanticBest(name, among: tied, embedder: embedder) ?? best.name
            }
            return best.name
        }
        // Nothing is spelled close. If the on-device model is available, try a
        // semantic match so a meaning-based typo ("pics" -> "Photos") still resolves.
        if let embedder { return semanticMatch(name, among: entries, embedder: embedder) }
        return nil
    }

    /// The most semantically similar entry to `name` (cosine), if it clears a
    /// confidence threshold. Bounded to keep an interactive lookup cheap.
    private static func semanticMatch(
        _ name: String, among entries: [String], embedder: TextEmbedder, threshold: Float = 0.45
    ) -> String? {
        guard let query = embedder.embed(name) else { return nil }
        var best: (name: String, score: Float)?
        for entry in entries.prefix(200) {
            guard let vector = embedder.embed(entry) else { continue }
            let score = cosine(query, vector)
            if best == nil || score > best!.score { best = (entry, score) }
        }
        guard let best, best.score >= threshold else { return nil }
        return best.name
    }

    /// Levenshtein edit distance (two-row, O(min(a,b)) space).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The candidate most semantically similar to `name` per the embedder (cosine),
    /// or nil if the model produced no vectors (asset unavailable).
    private static func semanticBest(_ name: String, among candidates: [String], embedder: TextEmbedder)
        -> String?
    {
        guard let query = embedder.embed(name) else { return nil }
        var best: (name: String, score: Float)?
        for candidate in candidates {
            guard let vector = embedder.embed(candidate) else { continue }
            let score = cosine(query, vector)
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        return best?.name
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}
