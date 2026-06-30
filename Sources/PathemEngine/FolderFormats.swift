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

        // Tolerant so one rule with a future/unknown scope doesn't fail the whole
        // [Rule] array (which would discard every saved per-folder view).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            scope = (try? c.decode(Scope.self, forKey: .scope)) ?? .exact
            format = (try? c.decode(ViewFormat.self, forKey: .format)) ?? .default
        }

        private enum CodingKeys: String, CodingKey { case path, scope, format }
    }

    public var rules: [Rule]
    public var defaultFormat: ViewFormat

    public init(rules: [Rule] = [], defaultFormat: ViewFormat = .default) {
        self.rules = rules
        self.defaultFormat = defaultFormat
    }

    // Tolerant: an older/partial formats.json loads with defaults instead of
    // failing and discarding every saved per-folder view.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaultFormat = try c.decodeIfPresent(ViewFormat.self, forKey: .defaultFormat) ?? .default
    }

    private enum CodingKeys: String, CodingKey { case rules, defaultFormat }

    /// Whether `path` has its own remembered format (an exact or subtree rule), as
    /// opposed to falling back to the default. Used to keep the view mode sticky across
    /// navigation only for folders the user hasn't explicitly configured.
    public func hasRule(for path: String) -> Bool {
        if rules.contains(where: { $0.scope == .exact && $0.path == path }) { return true }
        return rules.contains { $0.scope == .subtree && !$0.path.isEmpty && Self.isUnder(path, $0.path) }
    }

    /// The format for `path`: exact rule, else the most specific (longest)
    /// matching subtree rule, else the default.
    public func format(for path: String) -> ViewFormat {
        if let exact = rules.first(where: { $0.scope == .exact && $0.path == path }) {
            return exact.format
        }
        // An empty path is never a valid subtree root (it would match everything);
        // guards against a malformed/defaulted rule governing the whole disk.
        let matches = rules.filter { $0.scope == .subtree && !$0.path.isEmpty && Self.isUnder(path, $0.path) }
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

    /// Drop exact rules for folders strictly under `path` (not `path` itself), so
    /// a subtree rule applied to `path` actually governs descendants that the
    /// user had previously customized one by one.
    public mutating func clearExactRulesUnder(_ path: String) {
        rules.removeAll { $0.scope == .exact && $0.path != path && Self.isUnder($0.path, path) }
    }

    static func isUnder(_ path: String, _ prefix: String) -> Bool {
        // Tolerate a trailing slash on the (possibly hand-edited or shared)
        // prefix so a subtree rule still matches its own root folder.
        var base = prefix
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        if path == base { return true }
        if base == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(base + "/")
    }
}
