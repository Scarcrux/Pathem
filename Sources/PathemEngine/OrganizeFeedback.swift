import Foundation

/// A persisted, append-only log of behavioral signals about organize/cleanup suggestions:
/// explicit good/bad verdicts, and the implicit accept/skip decision the user makes each
/// time a plan is applied. It is the transparent behavior model: `confidenceBias` turns
/// the accumulated signals for a suggestion's (rule, extension) and destination into a
/// small, bounded nudge that the planner adds to a suggestion's confidence, so the tool
/// learns which suggestions you keep and which you skip. Pure Foundation, keyed to a file
/// the app owns, so it is unit-tested against a temp file.
public struct OrganizeFeedback: Codable, Sendable, Equatable {
    /// Explicit ratings (`good`/`bad`) count double; the implicit per-apply decision
    /// (`applied`/`skipped`) counts single. `routed` is an explicit correction of a
    /// suggestion's destination (the strongest signal: it says where these belong).
    public enum Verdict: String, Codable, Sendable, Equatable { case good, bad, applied, skipped, routed }

    public struct Entry: Codable, Sendable, Equatable {
        public var ruleID: String
        /// The move destination's folder name, or nil for a trash suggestion.
        public var destination: String?
        /// The full destination path the user re-routed to (for `.routed`), so the planner
        /// can send future files of this kind to the same place.
        public var destinationPath: String?
        /// The file's lowercased extension, so signals can be scoped by kind.
        public var ext: String
        public var verdict: Verdict

        public init(
            ruleID: String, destination: String?, ext: String, verdict: Verdict,
            destinationPath: String? = nil
        ) {
            self.ruleID = ruleID
            self.destination = destination
            self.destinationPath = destinationPath
            self.ext = ext
            self.verdict = verdict
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// Keep the log bounded so long-term use can't grow it without limit (oldest drop).
    static let maxEntries = 5000

    /// Tolerant load: a missing or malformed file yields an empty log rather than throwing.
    public static func load(from url: URL) -> OrganizeFeedback {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(OrganizeFeedback.self, from: data)
        else { return OrganizeFeedback() }
        return decoded
    }

    public static func record(_ entry: Entry, to url: URL) { record([entry], to: url) }

    /// Append signals and write back. Best-effort: a write failure is swallowed (feedback
    /// is advisory, never load-bearing for a file operation).
    public static func record(_ newEntries: [Entry], to url: URL) {
        guard !newEntries.isEmpty else { return }
        var log = load(from: url)
        log.entries.append(contentsOf: newEntries)
        if log.entries.count > maxEntries {
            log.entries.removeFirst(log.entries.count - maxEntries)
        }
        guard let data = try? JSONEncoder().encode(log) else { return }
        // Atomic: a crash mid-write would otherwise leave a truncated file. load() tolerates a
        // corrupt file by returning an empty log, but that silently discards the whole history;
        // the temp-file swap keeps the last good log intact until the new one is fully written.
        try? data.write(to: url, options: .atomic)
    }

    private static func weight(_ verdict: Verdict) -> Int {
        switch verdict {
        case .good, .routed: return 2  // routing to a destination is a strong positive for it
        case .applied: return 1
        case .skipped: return -1
        case .bad: return -2
        }
    }

    /// The destination the user has most recently re-routed this (rule, extension) to, if
    /// any. Most-recent wins, so a fresh correction supersedes an older one.
    public func preferredDestinationPath(ruleID: String, ext: String) -> String? {
        entries.last {
            $0.verdict == .routed && $0.ruleID == ruleID && $0.ext == ext && $0.destinationPath != nil
        }?.destinationPath
    }

    /// Weighted net signal for a rule (across all extensions).
    public func score(ruleID: String) -> Int {
        entries.filter { $0.ruleID == ruleID }.reduce(0) { $0 + Self.weight($1.verdict) }
    }

    /// Weighted net signal for a rule scoped to one extension.
    public func score(ruleID: String, ext: String) -> Int {
        entries.filter { $0.ruleID == ruleID && $0.ext == ext }.reduce(0) { $0 + Self.weight($1.verdict) }
    }

    /// Weighted net signal for a specific move destination.
    public func score(destination: String) -> Int {
        entries.filter { $0.destination == destination }.reduce(0) { $0 + Self.weight($1.verdict) }
    }

    /// A bounded confidence nudge in [-0.35, 0.35] for a candidate suggestion, from the
    /// accumulated signals for its (rule, extension) and its destination. Positive means
    /// the user tends to keep suggestions like this; negative means they tend to skip them.
    public func confidenceBias(ruleID: String, ext: String, destination: String?) -> Double {
        let ruleExt = score(ruleID: ruleID, ext: ext)
        let dest = destination.map { score(destination: $0) } ?? 0
        let raw = Double(ruleExt) * 0.04 + Double(dest) * 0.04
        return min(0.35, max(-0.35, raw))
    }
}
