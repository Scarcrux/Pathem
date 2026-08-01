import Foundation

/// A batch-rename rule (DESIGN.md roadmap). Pure data; the transform and
/// collision detection in `BatchRename` are unit-tested, and the rename itself
/// is a two-phase move that survives swaps and cycles.
public struct RenameRule: Sendable, Equatable, Codable {
    public enum CaseMode: String, Sendable, Equatable, Codable { case none, lower, upper, title }

    /// Find/replace applied to the name (literal, or a regex when `useRegex`).
    public var find: String
    public var replace: String
    public var useRegex: Bool
    public var prefix: String
    public var suffix: String
    public var caseMode: CaseMode
    /// When false (default) the extension is preserved and find/replace/case act
    /// only on the base name.
    public var includeExtension: Bool
    /// When non-nil, numbering is on: item i gets `counterStart + i*counterStep`,
    /// substituted into runs of `#` (padded to the run length), or appended
    /// (padded to `counterPadding`) when the template has no `#`.
    public var counterStart: Int?
    public var counterStep: Int
    public var counterPadding: Int

    public init(
        find: String = "", replace: String = "", useRegex: Bool = false,
        prefix: String = "", suffix: String = "", caseMode: CaseMode = .none,
        includeExtension: Bool = false, counterStart: Int? = nil,
        counterStep: Int = 1, counterPadding: Int = 1
    ) {
        self.find = find
        self.replace = replace
        self.useRegex = useRegex
        self.prefix = prefix
        self.suffix = suffix
        self.caseMode = caseMode
        self.includeExtension = includeExtension
        self.counterStart = counterStart
        self.counterStep = counterStep
        self.counterPadding = counterPadding
    }
}

/// Per-file values a rename template can interpolate via `{token}` tokens (date, parent folder,
/// EXIF capture date). Empty by default, so a rule with no tokens (or no metadata) is unaffected.
public struct RenameContext: Sendable, Equatable {
    public var modified: Date?
    public var created: Date?
    public var exifTaken: Date?
    public var parent: String
    public init(modified: Date? = nil, created: Date? = nil, exifTaken: Date? = nil, parent: String = "") {
        self.modified = modified
        self.created = created
        self.exifTaken = exifTaken
        self.parent = parent
    }
    public static let empty = RenameContext()
}

public struct RenamePair: Sendable, Equatable {
    public let original: String
    public let renamed: String
    public init(original: String, renamed: String) {
        self.original = original
        self.renamed = renamed
    }
}

public struct RenamePlan: Sendable, Equatable {
    public let pairs: [RenamePair]
    /// Renamed values that are unsafe: empty, duplicated within the set, or
    /// landing on an existing file that is not part of this rename.
    public let collisions: Set<String>
    public var hasCollisions: Bool { !collisions.isEmpty }
    public init(pairs: [RenamePair], collisions: Set<String>) {
        self.pairs = pairs
        self.collisions = collisions
    }
}

public struct RenameOutcome: Sendable, Equatable {
    public let renamed: Int
    public let failures: [String]
    public init(renamed: Int, failures: [String]) {
        self.renamed = renamed
        self.failures = failures
    }
}

public enum BatchRename {
    /// The new name for one item at `index` under `rule`.
    public static func newName(
        for original: String, index: Int, rule: RenameRule, context: RenameContext = .empty
    ) -> String {
        let ns = original as NSString
        let ext = rule.includeExtension ? "" : ns.pathExtension
        var base = rule.includeExtension ? original : ns.deletingPathExtension

        if !rule.find.isEmpty {
            if rule.useRegex, let regex = try? NSRegularExpression(pattern: rule.find) {
                let range = NSRange(base.startIndex..., in: base)
                base = regex.stringByReplacingMatches(in: base, range: range, withTemplate: rule.replace)
            } else {
                base = base.replacingOccurrences(of: rule.find, with: rule.replace)
            }
        }

        switch rule.caseMode {
        case .none: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .title: base = base.capitalized
        }

        // Interpolate {token}s the user typed in the prefix / suffix ({date}, {parent},
        // {exif.taken}, {name}, {ext}). No braces means no work and no change.
        let prefix = expandTokens(rule.prefix, original: original, context: context)
        let suffix = expandTokens(rule.suffix, original: original, context: context)
        var name = prefix + base + suffix

        if let start = rule.counterStart {
            name = applyCounter(to: name, value: start + index * rule.counterStep, padding: rule.counterPadding)
        }

        return ext.isEmpty ? name : name + "." + ext
    }

    /// The `{token}` vocabulary a rename prefix/suffix can use. Unknown tokens expand to empty.
    /// Dates take an optional strftime-style format after a colon, e.g. `{date:yyyyMMdd}`.
    static let tokenPattern = try! NSRegularExpression(pattern: #"\{([a-zA-Z.]+)(?::([^}]*))?\}"#)

    static func expandTokens(_ text: String, original: String, context: RenameContext) -> String {
        guard text.contains("{") else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = tokenPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {  // replace back-to-front so earlier ranges stay valid
            let name = source.substring(with: match.range(at: 1)).lowercased()
            let format = match.range(at: 2).location != NSNotFound ? source.substring(with: match.range(at: 2)) : nil
            result.replaceCharacters(in: match.range, with: tokenValue(name, format: format, original: original, context: context))
        }
        return result as String
    }

    private static func tokenValue(_ name: String, format: String?, original: String, context: RenameContext) -> String {
        let ns = original as NSString
        func date(_ value: Date?) -> String {
            guard let value else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format ?? "yyyy-MM-dd"
            return formatter.string(from: value)
        }
        switch name {
        case "name": return ns.deletingPathExtension
        case "ext": return ns.pathExtension
        case "parent": return context.parent
        case "date": return date(context.modified)
        case "created": return date(context.created)
        case "exif", "exif.taken": return date(context.exifTaken)
        default: return ""  // unknown token: expand to nothing
        }
    }

    /// Replace each run of `#` with the value padded to the run length; if the
    /// template has no `#`, append the value padded to `padding`.
    private static func applyCounter(to name: String, value: Int, padding: Int) -> String {
        guard name.contains("#") else {
            return name + String(format: "%0\(max(padding, 1))d", value)
        }
        var result = ""
        var run = 0
        func flush() {
            if run > 0 {
                result += String(format: "%0\(run)d", value)
                run = 0
            }
        }
        for ch in name {
            if ch == "#" {
                run += 1
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }

    /// The renamed values for `names`. `contexts` supplies per-file `{token}` values (date,
    /// parent, EXIF); a shorter/empty array falls back to `.empty` (tokens expand to nothing).
    public static func apply(_ rule: RenameRule, to names: [String], contexts: [RenameContext] = []) -> [String] {
        names.enumerated().map {
            newName(for: $1, index: $0, rule: rule, context: $0 < contexts.count ? contexts[$0] : .empty)
        }
    }

    /// Build a preview plan, flagging unsafe renamed values. `existing` is every
    /// name in the folder (used to catch a rename that would clobber a file not
    /// being renamed). `contexts` supplies per-file token values for the preview.
    public static func plan(
        _ rule: RenameRule, names: [String], existing: Set<String> = [], contexts: [RenameContext] = []
    ) -> RenamePlan {
        let renamed = apply(rule, to: names, contexts: contexts)
        let pairs = zip(names, renamed).map { RenamePair(original: $0, renamed: $1) }
        let originals = Set(names)
        var counts: [String: Int] = [:]
        for value in renamed { counts[value, default: 0] += 1 }

        var collisions = Set<String>()
        for (original, value) in zip(names, renamed) {
            if value.isEmpty { collisions.insert(value); continue }
            if counts[value]! > 1 { collisions.insert(value) }
            if value != original, existing.contains(value), !originals.contains(value) {
                collisions.insert(value)
            }
        }
        return RenamePlan(pairs: pairs, collisions: collisions)
    }

    /// Apply renames inside `directory`. Two-phase (move to unique temps, then to
    /// finals) so swaps and cycles (a->b, b->a) work. No-op pairs are skipped.
    public static func perform(in directory: URL, pairs: [RenamePair]) -> RenameOutcome {
        let fm = FileManager.default
        let work = pairs.filter { $0.original != $0.renamed && !$0.renamed.isEmpty }
        var staged: [(temp: URL, final: URL, original: String)] = []
        var failures: [String] = []

        for pair in work {
            let source = directory.appendingPathComponent(pair.original)
            let temp = directory.appendingPathComponent(".pathem-rename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: source, to: temp)
                staged.append((temp, directory.appendingPathComponent(pair.renamed), pair.original))
            } catch {
                failures.append("\(pair.original): \(error.localizedDescription)")
            }
        }

        var renamed = 0
        for item in staged {
            do {
                try fm.moveItem(at: item.temp, to: item.final)
                renamed += 1
            } catch {
                // Phase 2 failed. Restore to the original name; if that's occupied too, land the
                // file at a unique visible name rather than leaving it stranded under the hidden
                // ".pathem-rename-<UUID>" temp name where the user can't find it.
                let originalURL = directory.appendingPathComponent(item.original)
                if (try? fm.moveItem(at: item.temp, to: originalURL)) != nil {
                    failures.append("\(item.original): \(error.localizedDescription)")
                } else {
                    let fallback = FileOperations.uniqueDestination(originalURL)
                    if (try? fm.moveItem(at: item.temp, to: fallback)) != nil {
                        failures.append("\(item.original): \(error.localizedDescription) (kept as \(fallback.lastPathComponent))")
                    } else {
                        // Even the fallback move failed, so the file is still under the hidden temp
                        // name. Report that truthfully instead of claiming a name that doesn't exist.
                        failures.append(
                            "\(item.original): \(error.localizedDescription) (recover it at \(item.temp.lastPathComponent))")
                    }
                }
            }
        }
        return RenameOutcome(renamed: renamed, failures: failures)
    }
}
