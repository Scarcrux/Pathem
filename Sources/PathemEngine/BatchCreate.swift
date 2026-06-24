import Foundation

/// Batch creation of files or folders from a spec. Pure (real I/O only in `create`),
/// so name expansion is unit-tested. Two input styles, combinable line by line:
///  - a literal name per line ("notes.txt"), and
///  - a pattern with a `{start..end}` range that expands with zero-padding inferred
///    from the written width, e.g. "Chapter {01..12}" or "shot_{1..3}".
public enum BatchCreate {
    public enum Kind: String, Sendable, Codable, CaseIterable { case files, folders }

    /// Maximum items a single expansion will produce (a runaway-range guard).
    public static let limit = 10_000

    /// Expand the input into an ordered, de-duplicated list of valid item names.
    public static func expand(_ input: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for rawLine in input.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            for candidate in expandPattern(line) {
                let name = candidate.trimmingCharacters(in: .whitespaces)
                guard isValid(name), !seen.contains(name), out.count < limit else { continue }
                seen.insert(name)
                out.append(name)
            }
        }
        return out
    }

    /// Expand the first `{start..end}` range in `pattern`; returns `[pattern]` when
    /// there is no valid range.
    static func expandPattern(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
            let close = pattern[open...].firstIndex(of: "}")
        else { return [pattern] }
        let inside = String(pattern[pattern.index(after: open)..<close])
        let parts = inside.components(separatedBy: "..")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
            return [pattern]
        }
        let width = max(parts[0].count, parts[1].count)  // zero-pad to the wider token
        let prefix = String(pattern[..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let numbers = start <= end ? Array(start...end) : (end...start).reversed().map { $0 }
        return numbers.prefix(limit).map { n in
            let digits = String(abs(n))
            let padded = digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
            return prefix + (n < 0 ? "-" : "") + padded + suffix
        }
    }

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }

    /// Create the named items in `directory`. Existing names are skipped (no clobber).
    /// Returns the names actually created (for undo) and any failures.
    @discardableResult
    public static func create(_ names: [String], kind: Kind, in directory: URL)
        -> (created: [String], failures: [FileOperations.Failure])
    {
        let fm = FileManager.default
        var created: [String] = []
        var failures: [FileOperations.Failure] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { continue }
            do {
                if kind == .folders {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    guard fm.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                created.append(name)
            } catch {
                failures.append(FileOperations.Failure(name: name, reason: error.localizedDescription))
            }
        }
        return (created, failures)
    }
}
