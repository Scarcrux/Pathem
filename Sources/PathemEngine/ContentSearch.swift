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
