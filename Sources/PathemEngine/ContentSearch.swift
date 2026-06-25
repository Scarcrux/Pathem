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
            var args = ["--line-number", "--no-heading", "--color", "never", "--max-count", "100"]
            if !regex { args.append("--fixed-strings") }
            if !caseSensitive { args.append("--ignore-case") }
            args += ["--", query, folder.path]  // -- so a query starting with "-" isn't a flag
            guard let result = try? await RemoteRunner.run(rg, args) else { return [] }
            output = String(decoding: result.0, as: UTF8.self)
        } else {
            var args = ["-rnI"]  // recursive, line numbers, skip binary files
            if !caseSensitive { args.append("-i") }
            if !regex { args.append("-F") }  // fixed strings, not a regex
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
        let files = Set(matches.map(\.path))
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
                expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement),
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

    /// Parse "path:line:text" output (the common rg/grep -n form). A path may contain a
    /// colon, so match the *last* "path:digits:" boundary by anchoring on ":<digits>:".
    static func parse(_ output: String, limit: Int) -> [Match] {
        var matches: [Match] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let lineString = String(raw)
            guard let range = lineString.range(of: #":\d+:"#, options: .regularExpression) else { continue }
            let path = String(lineString[lineString.startIndex..<range.lowerBound])
            let number = Int(lineString[range].dropFirst().dropLast()) ?? 0
            let text = String(lineString[range.upperBound...])
            guard !path.isEmpty else { continue }
            matches.append(Match(path: path, line: number, text: text))
            if matches.count >= limit { break }
        }
        return matches
    }
}
