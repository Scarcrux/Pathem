import Foundation
import Testing

@testable import PathemEngine

@Suite struct RepoScanTests {
    @discardableResult
    private func git(_ args: [String], in dir: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func classifiesTrackedRegenerableAndPrecious() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        git(["init"], in: dir)
        git(["config", "user.email", "t@example.com"], in: dir)
        git(["config", "user.name", "Test"], in: dir)

        // Tracked file (staged is enough for ls-files).
        try Data("code".utf8).write(to: dir.appendingPathComponent("main.swift"))
        git(["add", "main.swift"], in: dir)

        // Untracked, not derivable: precious.
        try Data("rows".utf8).write(to: dir.appendingPathComponent("dataset.csv"))

        // Regenerable dependency tree.
        let nodeModules = dir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data("dep".utf8).write(to: nodeModules.appendingPathComponent("lib.js"))

        let items = await RepoScan.classify(dir)
        func disposition(_ name: String) -> RepoScan.Disposition? {
            items.first { $0.name == name }?.disposition
        }
        #expect(disposition("main.swift") == .tracked)
        #expect(disposition("dataset.csv") == .precious)
        #expect(disposition("node_modules") == .regenerable)
    }

    @Test func returnsEmptyOutsideARepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let items = await RepoScan.classify(dir)
        #expect(items.isEmpty)
    }
}
