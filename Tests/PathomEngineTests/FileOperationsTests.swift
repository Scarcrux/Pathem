import Foundation
import Testing

@testable import PathomEngine

@Suite struct FileOperationsTests {
    private func withTwoDirs(_ body: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathom-fileops-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(src, dst)
    }

    @Test func copyPlacesFileInDestinationAndKeepsSource() throws {
        try withTwoDirs { src, dst in
            try Data("hi".utf8).write(to: src.appendingPathComponent("a.txt"))
            let failures = FileOperations.copy(["a.txt"], from: src, to: dst)
            #expect(failures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
            #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
        }
    }

    @Test func moveRemovesFromSource() throws {
        try withTwoDirs { src, dst in
            try Data().write(to: src.appendingPathComponent("b.txt"))
            let failures = FileOperations.move(["b.txt"], from: src, to: dst)
            #expect(failures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("b.txt").path))
            #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("b.txt").path))
        }
    }

    @Test func refusesToOverwriteExistingDestination() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            let failures = FileOperations.copy(["c.txt"], from: src, to: dst)
            #expect(failures.count == 1)
            #expect(failures.first?.name == "c.txt")
            // Destination must be untouched.
            let content = try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8)
            #expect(content == "old")
        }
    }

    @Test func partialBatchReportsOnlyTheFailures() throws {
        try withTwoDirs { src, dst in
            try Data().write(to: src.appendingPathComponent("ok1.txt"))
            try Data().write(to: src.appendingPathComponent("clash.txt"))
            try Data().write(to: src.appendingPathComponent("ok2.txt"))
            try Data().write(to: dst.appendingPathComponent("clash.txt"))  // pre-existing

            let failures = FileOperations.copy(["ok1.txt", "clash.txt", "ok2.txt"], from: src, to: dst)
            #expect(failures.map(\.name) == ["clash.txt"])
            #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("ok1.txt").path))
            #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("ok2.txt").path))
        }
    }
}
