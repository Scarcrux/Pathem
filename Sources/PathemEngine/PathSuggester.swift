import Foundation

/// Resolves a typed or pasted path (absolute or relative) and, when it does not
/// exist, fuzzy-corrects each missing component against the real directory
/// contents to suggest the closest existing path ("did you mean ...").
///
/// Pure and AppKit-free, so the resolution and correction logic is unit-tested
/// without a UI. `locate` is the cheap existence check (safe on the main thread);
/// `suggest` is the heavier fuzzy/semantic search (callers run it off-main). A
/// case-insensitive edit-distance match is the always-available core; if the
/// optional on-device `TextEmbedder` model is present, it extends correction to
/// meaning-based matches and breaks ties among equally-close candidates.
public enum PathSuggester {
    /// How the input was interpreted.
    public enum Kind: Sendable, Equatable { case absolute, relative }

    public struct Resolution: Sendable, Equatable {
        public let kind: Kind
        /// Where the input pointed after expansion/standardization (may not exist).
        public let requested: URL
        /// The input itself, when it exists on disk (canonical on-disk casing).
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

    /// Cheap resolution: expand, classify absolute/relative, and check existence.
    /// No fuzzy scan, so it is safe to call on the main thread. The `suggestion` is
    /// always nil here; use `suggest(for:)` (off-main) for the "did you mean".
    public static func locate(_ raw: String, base: URL) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty input resolves to nothing (not silently to `base`).
        guard !trimmed.isEmpty else {
            return Resolution(kind: .relative, requested: base.standardizedFileURL, existing: nil, suggestion: nil)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let usedTilde = trimmed.hasPrefix("~")
        let isAbsolute = expanded.hasPrefix("/")
        let kind: Kind = (isAbsolute || usedTilde) ? .absolute : .relative
        // A "~user" that doesn't expand to an absolute path can't be resolved against
        // the process working directory; treat it as an unresolvable absolute ref
        // rather than joining the literal "~user" onto `base`.
        guard isAbsolute || !usedTilde else {
            return Resolution(kind: .absolute, requested: base.standardizedFileURL, existing: nil, suggestion: nil)
        }
        let target =
            (isAbsolute
            ? URL(fileURLWithPath: expanded)
            : base.appendingPathComponent(expanded)).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            return Resolution(kind: kind, requested: target, existing: nil, suggestion: nil)
        }
        // Return the real on-disk casing on case-insensitive volumes, without
        // resolving symlinks (so "/tmp" stays "/tmp", not "/private/tmp").
        return Resolution(kind: kind, requested: target, existing: realCased(target), suggestion: nil)
    }

    /// `url` with each component replaced by the real on-disk name (case-corrected),
    /// preserving symlinks. Used so a mis-cased but valid path displays correctly.
    private static func realCased(_ url: URL) -> URL {
        let fm = FileManager.default
        let components = url.pathComponents
        guard components.first == "/" else { return url }
        var current = URL(fileURLWithPath: "/")
        for component in components.dropFirst() {
            if let entries = try? fm.contentsOfDirectory(atPath: current.path),
                let real = entries.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            {
                current.appendPathComponent(real)
            } else {
                current.appendPathComponent(component)  // unreadable dir: keep as typed
            }
        }
        return current
    }

    /// Full resolution: `locate`, plus a fuzzy/semantic suggestion when it misses.
    /// Heavier (it may scan directories and load the model), so callers that care
    /// about the main thread should `locate` first and only call this off-main.
    public static func resolve(_ raw: String, base: URL, embedder: TextEmbedder? = nil) -> Resolution {
        let located = locate(raw, base: base)
        guard located.existing == nil else { return located }
        return Resolution(
            kind: located.kind, requested: located.requested, existing: nil,
            suggestion: suggest(for: located.requested, embedder: embedder))
    }

    /// Walk from the filesystem root, fuzzy-correcting each missing component to the
    /// closest existing child. Returns the closest fully-reconstructable existing
    /// path, or nil if any component has no match (so the result never depends on
    /// how far an unfixable leaf happened to get).
    public static func suggest(for target: URL, embedder: TextEmbedder? = nil) -> URL? {
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
            guard let match = bestMatch(component, in: current, embedder: embedder) else {
                return nil  // an unfixable component: no consistent suggestion
            }
            current = current.appendingPathComponent(match)
            corrected = true
        }
        guard corrected, current != target, fm.fileExists(atPath: current.path) else { return nil }
        return current.standardizedFileURL
    }

    /// The closest existing child name in `directory` to `name`: an exact
    /// case-insensitive match, else the nearest by edit distance within tolerance,
    /// else (with the model) the closest by meaning.
    static func bestMatch(_ name: String, in directory: URL, embedder: TextEmbedder?) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path), !entries.isEmpty else {
            return nil
        }
        if let exact = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let lowerName = name.lowercased()
        // Allowed distance grows with length but is always < the name length, so an
        // entirely different short string can never match (no whole-string swaps).
        let tolerance = min(name.count - 1, max(1, name.count / 3))
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
    /// confidence threshold. The scan is bounded; entries are pre-ranked by cheap
    /// character overlap so the cap keeps plausible candidates, not an arbitrary slice.
    private static func semanticMatch(
        _ name: String, among entries: [String], embedder: TextEmbedder, threshold: Float = 0.45
    ) -> String? {
        guard let query = embedder.embed(name) else { return nil }
        let querySet = Set(name.lowercased())
        let ranked = entries
            .map { (name: $0, overlap: querySet.intersection(Set($0.lowercased())).count) }
            .sorted { $0.overlap > $1.overlap }
            .prefix(200)
            .map(\.name)
        var best: (name: String, score: Float)?
        for candidate in ranked {
            guard let vector = embedder.embed(candidate) else { continue }
            let score = cosine(query, vector)
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        guard let best, best.score >= threshold else { return nil }
        return best.name
    }

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
