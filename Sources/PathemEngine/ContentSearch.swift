import Foundation

/// Searches file CONTENTS under a folder (grep across files), via ripgrep when present
/// (fast, gitignore-aware, skips binaries) or the system grep otherwise. Out-of-process.
/// The output parser is pure, so it's unit-tested.
public enum ContentSearch {
    public struct Match: Sendable, Equatable {
        public let path: String
        public let line: Int
        public let text: String
        public init(path: String, line: Int, text: String) {
            self.path = path
            self.line = line
            self.text = text
        }
    }

    static var ripgrep: String? {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func search(
        _ query: String, in folder: URL, regex: Bool = false, caseSensitive: Bool = false,
        maxResults: Int = 2000
    ) async -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let output: String
        if let rg = ripgrep {
            // --null ends each path with NUL, so a path containing ":<digits>:" or a newline
            // cannot be mistaken for the path/line boundary.
            var args = [
                "--null", "--line-number", "--no-heading", "--color", "never", "--max-count", "100",
            ]
            if !regex { args.append("--fixed-strings") }
            if !caseSensitive { args.append("--ignore-case") }
            args += ["--", query, folder.path]  // -- so a query starting with "-" isn't a flag
            guard let result = try? await RemoteRunner.run(rg, args) else { return [] }
            output = String(decoding: result.0, as: UTF8.self)
        } else {
            var args = ["-rnI", "--null"]  // recursive, line numbers, skip binaries, NUL after path
            if !caseSensitive { args.append("-i") }
            // The UI's regex contract uses extended syntax (groups and `|`). macOS grep defaults
            // to basic regex, where those are literals, so explicitly select ERE when rg is absent.
            args.append(regex ? "-E" : "-F")
            args += ["-e", query, folder.path]
            guard let result = try? await RemoteRunner.run("/usr/bin/grep", args) else { return [] }
            output = String(decoding: result.0, as: UTF8.self)
        }
        return parse(output, limit: maxResults)
    }

    public struct ReplaceResult: Sendable, Equatable {
        public let filesChanged: Int
        public let replacements: Int
        public init(filesChanged: Int, replacements: Int) {
            self.filesChanged = filesChanged
            self.replacements = replacements
        }
    }

    /// Replace every match of `query` with `replacement` across the files under `folder`
    /// that contain it. Only UTF-8 text files are rewritten (binaries skipped), each
    /// written atomically. Regex replacement uses ICU templates ($1, $2). This edits files
    /// in place and is not undoable, so the UI confirms first.
    public static func replaceAll(
        _ query: String, with replacement: String, in folder: URL, regex: Bool = false,
        caseSensitive: Bool = false
    ) async -> ReplaceResult {
        let matches = await search(
            query, in: folder, regex: regex, caseSensitive: caseSensitive, maxResults: 1_000_000)
        // Independent write-scope check: only files strictly inside `folder` are rewritten,
        // whatever the search tool printed.
        let files = Set(matches.map(\.path)).filter { isInside($0, folder) }
        var filesChanged = 0
        var replacements = 0
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (updated, count) = applyReplace(
                to: original, query: query, replacement: replacement, regex: regex,
                caseSensitive: caseSensitive)
            guard count > 0, updated != original,
                (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil
            else { continue }
            filesChanged += 1
            replacements += count
        }
        return ReplaceResult(filesChanged: filesChanged, replacements: replacements)
    }

    /// Whether `path` is strictly inside `folder`, after resolving `..` and symlinks. Replace
    /// All checks this itself and never trusts a path just because the search tool printed it.
    static func isInside(_ path: String, _ folder: URL) -> Bool {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Pure replacement over one string; returns the new text and how many matches were
    /// replaced. Regex uses NSRegularExpression (ICU); literal uses replacingOccurrences.
    static func applyReplace(
        to text: String, query: String, replacement: String, regex: Bool, caseSensitive: Bool
    ) -> (String, Int) {
        if regex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: query, options: options) else {
                return (text, 0)
            }
            let range = NSRange(text.startIndex..., in: text)
            let count = expression.numberOfMatches(in: text, range: range)
            guard count > 0 else { return (text, 0) }
            return (
                expression.stringByReplacingMatches(
                    in: text, range: range, withTemplate: replacement),
                count
            )
        }
        let compare: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var count = 0
        var cursor = text.startIndex
        while let found = text.range(of: query, options: compare, range: cursor..<text.endIndex) {
            count += 1
            cursor = found.upperBound
        }
        guard count > 0 else { return (text, 0) }
        return (text.replacingOccurrences(of: query, with: replacement, options: compare), count)
    }

    /// Parse `path NUL line ":" text "\n"` records (rg/grep `--null -n`). The path ends at
    /// the NUL, so it may contain colons, digits or newlines; the text ends at the newline.
    /// Records without a NUL are refused rather than guessed at.
    static func parse(_ output: String, limit: Int) -> [Match] {
        var matches: [Match] = []
        var rest = Substring(output)
        while matches.count < limit, let nul = rest.firstIndex(of: "\u{0}") {
            let path = String(rest[rest.startIndex..<nul])
            let afterNul = rest[rest.index(after: nul)...]
            let lineEnd = afterNul.firstIndex(where: \.isNewline) ?? afterNul.endIndex
            let record = afterNul[afterNul.startIndex..<lineEnd]
            rest = lineEnd < afterNul.endIndex ? afterNul[afterNul.index(after: lineEnd)...] : ""
            guard let colon = record.firstIndex(of: ":"),
                let number = Int(record[record.startIndex..<colon]), !path.isEmpty
            else { continue }
            matches.append(
                Match(path: path, line: number, text: String(record[record.index(after: colon)...]))
            )
        }
        return matches
    }
}
