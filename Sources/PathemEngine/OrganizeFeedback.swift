import Foundation

/// A persisted log of the user's good/bad verdicts on organize suggestions. This is
/// the honest seed of the behavior model: for now it just records the signal (so the
/// feedback buttons do something real and data starts accumulating), and a later phase
/// reads `score(ruleID:)` / `score(destination:)` to bias the ranking. Pure Foundation,
/// keyed to a file the app owns, so it is unit-tested against a temp file.
public struct OrganizeFeedback: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, Equatable { case good, bad }

    public struct Entry: Codable, Sendable, Equatable {
        public var ruleID: String
        /// The move destination's folder name, or nil for a trash suggestion.
        public var destination: String?
        /// The file's lowercased extension, so feedback can later be scoped by kind.
        public var ext: String
        public var verdict: Verdict

        public init(ruleID: String, destination: String?, ext: String, verdict: Verdict) {
            self.ruleID = ruleID
            self.destination = destination
            self.ext = ext
            self.verdict = verdict
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// Tolerant load: a missing or malformed file yields an empty log rather than throwing.
    public static func load(from url: URL) -> OrganizeFeedback {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(OrganizeFeedback.self, from: data)
        else { return OrganizeFeedback() }
        return decoded
    }

    /// Append one verdict and write it back. Best-effort: a write failure is swallowed
    /// (feedback is advisory, never load-bearing for a file operation).
    public static func record(_ entry: Entry, to url: URL) {
        var log = load(from: url)
        log.entries.append(entry)
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url)
    }

    /// Net verdict for a rule (good minus bad), the signal a later ranking phase reads.
    public func score(ruleID: String) -> Int {
        entries.filter { $0.ruleID == ruleID }
            .reduce(0) { $0 + ($1.verdict == .good ? 1 : -1) }
    }

    /// Net verdict for a specific move destination.
    public func score(destination: String) -> Int {
        entries.filter { $0.destination == destination }
            .reduce(0) { $0 + ($1.verdict == .good ? 1 : -1) }
    }
}
