import Foundation

/// One released version's entry in the in-app changelog.
public struct ChangelogEntry: Equatable, Sendable {
    /// The version string as written in the heading, e.g. "0.9.0".
    public let version: String
    /// The date text as written, e.g. "2026-07-26", or nil when the heading omits it.
    public let date: String?
    /// The bullet lines under the heading, with the leading "- " / "* " stripped.
    public let notes: [String]

    public init(version: String, date: String?, notes: [String]) {
        self.version = version
        self.date = date
        self.notes = notes
    }
}

/// Parses the bundled `CHANGELOG.md` into per-version entries so the app can show
/// release notes on demand. Deliberately tiny and forgiving: it only recognizes
/// `## <version> - <date>` headings and `-`/`*` bullet lines, ignoring everything
/// else (the file title, prose, blank lines). Entries come back in file order, so
/// author the changelog newest-first and that's how it displays.
public enum ChangelogParser {
    public static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var version: String?
        var date: String?
        var notes: [String] = []

        func flush() {
            if let version {
                entries.append(ChangelogEntry(version: version, date: date, notes: notes))
            }
            version = nil
            date = nil
            notes = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                let heading = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                // Split "version - date" on the first " - "; a heading with no separator is
                // all version, no date.
                if let sep = heading.range(of: " - ") {
                    version = String(heading[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let tail = String(heading[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                    date = tail.isEmpty ? nil : tail
                } else {
                    version = heading
                    date = nil
                }
            } else if version != nil, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                notes.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return entries
    }
}
