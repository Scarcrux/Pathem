import Foundation

/// A user rule that colors and styles a filename when it matches, like Directory Opus
/// labels. Rules are config-as-data (persisted as colorrules.json); the first enabled
/// rule that matches an entry wins. Pure matching, so it's unit-tested.
public struct ColorRule: Codable, Sendable, Equatable, Identifiable {
    /// What part of the entry the rule tests.
    public enum Field: String, Codable, Sendable, CaseIterable { case ext, name, size, kind }
    /// How the field is tested. Not every op applies to every field (the editor shows the
    /// relevant ones); `matches` interprets them per field.
    public enum Op: String, Codable, Sendable, CaseIterable {
        case isAnyOf  // ext: a comma list; kind: "folder"/"file"
        case contains, beginsWith, endsWith, matches  // name (`matches` is a * ? glob)
        case greaterThan, lessThan  // size, with `value` in MB
    }

    public var id: UUID
    public var name: String  // a label for the rule row
    public var enabled: Bool
    public var field: Field
    public var op: Op
    public var value: String
    public var colorHex: String  // "" = keep the default text color
    public var bold: Bool
    public var italic: Bool

    public init(
        id: UUID = UUID(), name: String = "", enabled: Bool = true, field: Field = .ext,
        op: Op = .isAnyOf, value: String = "", colorHex: String = "", bold: Bool = false,
        italic: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.field = field
        self.op = op
        self.value = value
        self.colorHex = colorHex
        self.bold = bold
        self.italic = italic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        field = (try? c.decode(Field.self, forKey: .field)) ?? .ext
        op = (try? c.decode(Op.self, forKey: .op)) ?? .isAnyOf
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
    }

    /// Whether this rule matches an entry. `size` is in bytes.
    public func matches(name entryName: String, isDirectory: Bool, size: Int64) -> Bool {
        let lower = entryName.lowercased()
        switch field {
        case .ext:
            guard !isDirectory else { return false }  // folders have no extension
            let ext = (entryName as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            let wanted = value.lowercased()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "." })
                .map(String.init)
            return wanted.contains(ext)
        case .name:
            let v = value.lowercased()
            switch op {
            case .beginsWith: return lower.hasPrefix(v)
            case .endsWith: return lower.hasSuffix(v)
            case .matches: return Glob.match(pattern: value, name: entryName)
            default: return !v.isEmpty && lower.contains(v)  // .contains (and any stray op)
            }
        case .size:
            guard !isDirectory, let mb = Double(value) else { return false }
            let threshold = Int64(mb * 1_000_000)
            return op == .lessThan ? size < threshold : size > threshold
        case .kind:
            return value.lowercased().hasPrefix("folder") ? isDirectory : !isDirectory
        }
    }
}

/// The ordered list of color rules (config-as-data). The first enabled rule that matches
/// an entry decides its color and style.
public struct ColorRules: Codable, Sendable, Equatable {
    public var rules: [ColorRule]

    public init(rules: [ColorRule] = []) { self.rules = rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([ColorRule].self, forKey: .rules) ?? []
    }

    private enum CodingKeys: String, CodingKey { case rules }

    /// The first enabled rule matching this entry, or nil.
    public func match(name: String, isDirectory: Bool, size: Int64) -> ColorRule? {
        rules.first { $0.enabled && $0.matches(name: name, isDirectory: isDirectory, size: size) }
    }
}

/// A minimal case-insensitive shell glob (`*` any run, `?` one char), for name rules.
public enum Glob {
    public static func match(pattern: String, name: String) -> Bool {
        let p = Array(pattern.lowercased()), s = Array(name.lowercased())
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = si
                pi += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
