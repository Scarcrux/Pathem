import Foundation

/// Read-only git status overlays. Shells out to the system `git` OUT OF PROCESS
/// (never libgit2, so no GPL), parses `--porcelain=v2 -z`, and returns per-path
/// states plus the branch. The parser is pure and unit-tested against sample
/// output; only `status(for:)` touches a subprocess.
public enum GitFileState: String, Sendable, Equatable {
    case modified, added, deleted, renamed, untracked, conflicted
}

public struct GitInfo: Sendable, Equatable {
    public var branch: String?
    public var ahead: Int
    public var behind: Int
    /// Absolute path -> state. Directories containing changes are marked `.modified`.
    public var states: [String: GitFileState]

    public init(branch: String? = nil, ahead: Int = 0, behind: Int = 0, states: [String: GitFileState] = [:]) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.states = states
    }
}

public enum GitStatus {
    static let git = "/usr/bin/git"

    /// Git status for the repo containing `folder`, or nil if it isn't a repo / git
    /// is unavailable. Runs off-process.
    public static func status(for folder: URL) async -> GitInfo? {
        guard FileManager.default.isExecutableFile(atPath: git) else { return nil }
        guard
            let root = try? await RemoteRunner.run(
                git, ["-C", folder.path, "rev-parse", "--show-toplevel"]),
            root.1 == 0
        else { return nil }  // not a repository
        let rootPath = String(decoding: root.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return nil }
        guard
            let result = try? await RemoteRunner.run(
                git, ["-C", folder.path, "status", "--porcelain=v2", "--branch", "-z"]),
            result.1 == 0
        else { return nil }
        return parse(porcelainZ: String(decoding: result.0, as: UTF8.self), repoRoot: URL(fileURLWithPath: rootPath))
    }

    /// Parse `git status --porcelain=v2 --branch -z` into a GitInfo. Records are
    /// NUL-separated; a rename record (`2`) is followed by its origin path in the
    /// next record.
    public static func parse(porcelainZ output: String, repoRoot: URL) -> GitInfo {
        var info = GitInfo()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                info.branch = name == "(detached)" ? nil : name
            } else if record.hasPrefix("# branch.ab ") {
                for token in record.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if token.hasPrefix("+") { info.ahead = Int(token.dropFirst()) ?? 0 }
                    if token.hasPrefix("-") { info.behind = Int(token.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("# ") {
                continue  // other headers (oid, upstream)
            } else if record.hasPrefix("1 ") {
                if let (path, xy) = pathAndXY(record, fieldsBeforePath: 8) {
                    set(state(xy), at: path, repoRoot: repoRoot, into: &info)
                }
            } else if record.hasPrefix("2 ") {
                if let (path, _) = pathAndXY(record, fieldsBeforePath: 9) {
                    set(.renamed, at: path, repoRoot: repoRoot, into: &info)
                }
                index += 1  // skip the origin-path record that follows a rename
            } else if record.hasPrefix("u ") {
                if let (path, _) = pathAndXY(record, fieldsBeforePath: 10) {
                    set(.conflicted, at: path, repoRoot: repoRoot, into: &info)
                }
            } else if record.hasPrefix("? ") {
                set(.untracked, at: String(record.dropFirst(2)), repoRoot: repoRoot, into: &info)
            }
        }
        return info
    }

    /// Split a `1`/`2`/`u` record into its path (everything after the first
    /// `fieldsBeforePath` single-space-separated fields) and its two-char XY status.
    /// The path is taken as a verbatim substring so consecutive spaces in a name are
    /// preserved (split+join would collapse them).
    private static func pathAndXY(_ record: String, fieldsBeforePath: Int) -> (path: String, xy: String)? {
        var spaces = 0
        var index = record.startIndex
        while index < record.endIndex {
            if record[index] == " " {
                spaces += 1
                if spaces == fieldsBeforePath {
                    let start = record.index(after: index)
                    guard start < record.endIndex else { return nil }
                    let head = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    let xy = head.count > 1 ? String(head[1]) : ".."
                    return (String(record[start...]), xy)
                }
            }
            index = record.index(after: index)
        }
        return nil
    }

    private static func state(_ xy: String) -> GitFileState {
        if xy.contains("D") { return .deleted }
        if xy.contains("A") { return .added }
        if xy.contains("R") || xy.contains("C") { return .renamed }
        return .modified
    }

    /// Record `state` for `relativePath` and mark its ancestor directories (up to the
    /// repo root) `.modified`, so a folder containing changes shows a badge.
    private static func set(
        _ state: GitFileState, at relativePath: String, repoRoot: URL, into info: inout GitInfo
    ) {
        let clean = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
        guard !clean.isEmpty else { return }
        let full = repoRoot.appendingPathComponent(clean)
        info.states[full.path] = state
        var parent = full.deletingLastPathComponent()
        while parent.path.count > repoRoot.path.count, parent.path.hasPrefix(repoRoot.path) {
            if info.states[parent.path] == nil { info.states[parent.path] = .modified }
            parent = parent.deletingLastPathComponent()
        }
    }
}
