import Foundation

/// A rule for selecting entries in a listing by name and kind: a shell glob (`*.log`,
/// `IMG_?.jpg`) by default, a full regular expression, or a plain substring, optionally
/// restricted to files or folders. Pure and testable; the app compiles it once into a
/// predicate and applies it to the current listing (replace / add / subtract).
public struct SelectionQuery: Sendable, Equatable {
    public enum Match: String, Sendable, CaseIterable { case glob, regex, substring }
    public enum Kind: String, Sendable, CaseIterable { case any, files, folders }

    public var pattern: String
    public var match: Match
    public var kind: Kind
    public var caseSensitive: Bool

    public init(
        pattern: String, match: Match = .glob, kind: Kind = .any, caseSensitive: Bool = false
    ) {
        self.pattern = pattern
        self.match = match
        self.kind = kind
        self.caseSensitive = caseSensitive
    }

    /// Compile the query once, then test many entries. An empty pattern matches every entry
    /// of the chosen kind; an invalid regex matches nothing.
    public func predicate() -> (FileEntry) -> Bool {
        let kind = self.kind
        func kindMatches(_ entry: FileEntry) -> Bool {
            switch kind {
            case .any: return true
            case .files: return !entry.isDirectory
            case .folders: return entry.isDirectory
            }
        }

        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return kindMatches }

        switch match {
        case .substring:
            let sensitive = caseSensitive
            let needle = sensitive ? trimmed : trimmed.lowercased()
            return { entry in
                guard kindMatches(entry) else { return false }
                let name = sensitive ? entry.name : entry.name.lowercased()
                return name.contains(needle)
            }
        case .glob, .regex:
            let source = match == .glob ? Self.globToRegex(trimmed) : trimmed
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: source, options: options) else {
                return { _ in false }  // an unparseable pattern selects nothing, rather than everything
            }
            return { entry in
                guard kindMatches(entry) else { return false }
                let range = NSRange(entry.name.startIndex..., in: entry.name)
                return regex.firstMatch(in: entry.name, options: [], range: range) != nil
            }
        }
    }

    /// Translate a shell-style glob (`*`, `?`, `[...]`) into an anchored regex. Regex
    /// metacharacters that aren't glob operators are escaped so they match literally
    /// (so the glob `a.b` matches "a.b", not "axb").
    static func globToRegex(_ glob: String) -> String {
        let chars = Array(glob)
        var out = "^"
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                out += ".*"
                i += 1
            case "?":
                out += "."
                i += 1
            case "[":
                if let close = classClose(chars, openAt: i) {
                    out += "["
                    var k = i + 1
                    if k < close, chars[k] == "!" {
                        out += "^"  // glob negation
                        k += 1
                    }
                    while k < close {
                        out.append(chars[k])
                        k += 1
                    }
                    out += "]"
                    i = close + 1
                } else {
                    out += "\\["  // no closing bracket: a literal "["
                    i += 1
                }
            default:
                if "\\^$.|+()[]{}".contains(c) { out += "\\" }
                out.append(c)
                i += 1
            }
        }
        out += "$"
        return out
    }

    /// The index of the `]` closing a class opened at `openAt`, or nil if none. A `]` in
    /// the first position (optionally after `!`) is a literal class member, not the close.
    private static func classClose(_ chars: [Character], openAt open: Int) -> Int? {
        var k = open + 1
        if k < chars.count, chars[k] == "!" { k += 1 }
        if k < chars.count, chars[k] == "]" { k += 1 }
        while k < chars.count {
            if chars[k] == "]" { return k }
            k += 1
        }
        return nil
    }
}
