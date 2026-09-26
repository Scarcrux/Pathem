import Foundation
import Testing

@testable import PathemEngine

/// Integration test: drives the REAL `git` subprocess against a throwaway repo, so
/// the status path (rev-parse + status --porcelain=v2 -z + parse) is exercised end
/// to end, not just the parser. Skips cleanly where git is unavailable.
@Suite struct GitStatusIntegrationTests {
    private static let git = "/usr/bin/git"

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.git)
        process.arguments = args
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        // Isolate from the developer's global/system git config.
        var env = GitStatus.subprocessEnvironment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func realRepositoryStatusIsParsed() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.git) else { return }  // no git: skip
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        try run(["-c", "init.defaultBranch=main", "init"], in: repo)
        try run(["config", "user.email", "t@example.com"], in: repo)
        try run(["config", "user.name", "Test"], in: repo)
        try run(["config", "core.hooksPath", "/dev/null"], in: repo)
        try Data("v1".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try run(["add", "."], in: repo)
        try run(["commit", "-m", "init"], in: repo)

        // Now make a real working-tree state: one modified, one untracked.
        try Data("v2-longer".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("new".utf8).write(to: repo.appendingPathComponent("fresh.txt"))

        let info = await GitStatus.status(for: repo)
        let result = try #require(info)
        #expect(result.branch == "main")
        // Match by suffix: rev-parse canonicalizes /var -> /private/var on macOS.
        #expect(
            result.states.contains { $0.key.hasSuffix("/tracked.txt") && $0.value == .modified })
        #expect(result.states.contains { $0.key.hasSuffix("/fresh.txt") && $0.value == .untracked })
    }

    @Test func nonRepositoryReturnsNil() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.git) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await GitStatus.status(for: dir) == nil)  // not a repo
    }

    /// Reading status must NOT mutate the repo. Without `--no-optional-locks`, `git status`
    /// refreshes and rewrites `.git/index` when a tracked file's stat is stale, which makes
    /// the pane's watcher fire, reload, and re-poll status forever (the list flickers). Here
    /// we deliberately stale the index (same content, older mtime) and assert the index bytes
    /// are byte-identical before and after a status read. This fails on the pre-fix code.
    @Test func statusDoesNotRewriteTheIndex() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.git) else { return }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-gitidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        try run(["-c", "init.defaultBranch=main", "init"], in: repo)
        try run(["config", "user.email", "t@example.com"], in: repo)
        try run(["config", "user.name", "Test"], in: repo)
        try run(["config", "core.hooksPath", "/dev/null"], in: repo)
        let file = repo.appendingPathComponent("tracked.txt")
        try Data("hello world".utf8).write(to: file)
        try run(["add", "."], in: repo)
        try run(["commit", "-m", "init"], in: repo)

        // Same content, older mtime: a normal `git status` would refresh the index stat
        // cache and rewrite .git/index. --no-optional-locks must suppress that write.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100_000)], ofItemAtPath: file.path)

        let indexURL = repo.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: indexURL)
        _ = await GitStatus.status(for: repo)
        let after = try Data(contentsOf: indexURL)
        #expect(before == after)  // status did not rewrite the index
    }
}
