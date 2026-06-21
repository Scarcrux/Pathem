import Foundation

/// Per-folder view formats with a Directory-Opus-style precedence cascade
/// (DESIGN.md section 10): an exact-path rule beats the longest matching subtree
/// rule, which beats the global default. Stored as config-as-data (one JSON
/// object) so views are remembered per folder, applied to whole subtrees, and
/// shareable.
public struct FolderFormats: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case exact, subtree }

    public struct Rule: Codable, Sendable, Equatable {
        public var path: String
        public var scope: Scope
        public var format: ViewFormat
        public init(path: String, scope: Scope, format: ViewFormat) {
            self.path = path
            self.scope = scope
            self.format = format
        }
    }

    public var rules: [Rule]
    public var defaultFormat: ViewFormat

    public init(rules: [Rule] = [], defaultFormat: ViewFormat = .default) {
        self.rules = rules
        self.defaultFormat = defaultFormat
    }

    /// The format for `path`: exact rule, else the most specific (longest)
    /// matching subtree rule, else the default.
    public func format(for path: String) -> ViewFormat {
        if let exact = rules.first(where: { $0.scope == .exact && $0.path == path }) {
            return exact.format
        }
        let matches = rules.filter { $0.scope == .subtree && Self.isUnder(path, $0.path) }
        if let best = matches.max(by: { $0.path.count < $1.path.count }) {
            return best.format
        }
        return defaultFormat
    }

    /// Remember a format for exactly this folder (the auto-remember case).
    public mutating func setExact(_ path: String, _ format: ViewFormat) {
        rules.removeAll { $0.scope == .exact && $0.path == path }
        rules.append(Rule(path: path, scope: .exact, format: format))
    }

    /// Apply a format to this folder and all descendants (apply-to-subfolders).
    public mutating func setSubtree(_ path: String, _ format: ViewFormat) {
        rules.removeAll { $0.scope == .subtree && $0.path == path }
        rules.append(Rule(path: path, scope: .subtree, format: format))
    }

    static func isUnder(_ path: String, _ prefix: String) -> Bool {
        if path == prefix { return true }
        let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.hasPrefix(normalized)
    }
}
