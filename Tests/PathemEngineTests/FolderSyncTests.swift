import Foundation
import Testing

@testable import PathemEngine

@Suite struct FolderSyncTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ s: String, _ url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.data(using: .utf8)!.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    @Test func additivelyCopiesBothWaysAndResolvesByNewer() throws {
        let left = try tempDir(); let right = try tempDir()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write("a", left.appendingPathComponent("onlyLeft.txt"))
        try write("b", right.appendingPathComponent("onlyRight.txt"))
        // Same name, differing; left is newer -> left should win.
        try write("old", right.appendingPathComponent("both.txt"), modified: Date(timeIntervalSinceNow: -1000))
        try write("new", left.appendingPathComponent("both.txt"), modified: Date())

        let actions = FolderSync.plan(left: left, right: right)
        let result = FolderSync.execute(actions, left: left, right: right)
        #expect(result.failures.isEmpty)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: right.appendingPathComponent("onlyLeft.txt").path))  // copied right
        #expect(fm.fileExists(atPath: left.appendingPathComponent("onlyRight.txt").path))  // copied left
        // Newer (left) content propagated to right.
        #expect((try? String(contentsOf: right.appendingPathComponent("both.txt"), encoding: .utf8)) == "new")
    }

    @Test func skipPolicyLeavesConflictsUntouched() throws {
        let left = try tempDir(); let right = try tempDir()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write("L", left.appendingPathComponent("c.txt"))
        try write("R", right.appendingPathComponent("c.txt"))

        let actions = FolderSync.plan(left: left, right: right, conflict: .skip)
        let result = FolderSync.execute(actions, left: left, right: right)
        #expect(result.conflictsSkipped == 1)
        #expect(result.copiedToLeft == 0 && result.copiedToRight == 0)
        #expect((try? String(contentsOf: left.appendingPathComponent("c.txt"), encoding: .utf8)) == "L")
        #expect((try? String(contentsOf: right.appendingPathComponent("c.txt"), encoding: .utf8)) == "R")
    }
}
