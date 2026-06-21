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

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func copyPlacesFileInDestinationAndKeepsSource() throws {
        try withTwoDirs { src, dst in
            try Data("hi".utf8).write(to: src.appendingPathComponent("a.txt"))
            let outcome = FileOperations.copy(["a.txt"], from: src, to: dst)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.performed.count == 1)
            #expect(exists(dst.appendingPathComponent("a.txt")))
            #expect(exists(src.appendingPathComponent("a.txt")))
        }
    }

    @Test func moveRemovesFromSource() throws {
        try withTwoDirs { src, dst in
            try Data().write(to: src.appendingPathComponent("b.txt"))
            let outcome = FileOperations.move(["b.txt"], from: src, to: dst)
            #expect(outcome.failures.isEmpty)
            #expect(exists(dst.appendingPathComponent("b.txt")))
            #expect(!exists(src.appendingPathComponent("b.txt")))
        }
    }

    @Test func skipsExistingByDefault() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst)
            #expect(outcome.skipped == ["c.txt"])
            #expect(outcome.failures.isEmpty)
            let content = try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8)
            #expect(content == "old")  // destination untouched
        }
    }

    @Test func replaceOverwritesDestination() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst, onConflict: .replace)
            #expect(outcome.performed.count == 1)
            let content = try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8)
            #expect(content == "new")
        }
    }

    @Test func keepBothMakesACopyName() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst, onConflict: .keepBoth)
            #expect(outcome.performed.count == 1)
            #expect(exists(dst.appendingPathComponent("c.txt")))  // original kept
            #expect(exists(dst.appendingPathComponent("c copy.txt")))  // new one renamed
        }
    }

    @Test func partialBatchSkipsOnlyTheConflict() throws {
        try withTwoDirs { src, dst in
            try Data().write(to: src.appendingPathComponent("ok1.txt"))
            try Data().write(to: src.appendingPathComponent("clash.txt"))
            try Data().write(to: src.appendingPathComponent("ok2.txt"))
            try Data().write(to: dst.appendingPathComponent("clash.txt"))  // pre-existing

            let outcome = FileOperations.copy(["ok1.txt", "clash.txt", "ok2.txt"], from: src, to: dst)
            #expect(outcome.skipped == ["clash.txt"])
            #expect(exists(dst.appendingPathComponent("ok1.txt")))
            #expect(exists(dst.appendingPathComponent("ok2.txt")))
        }
    }

    @Test func undoMoveMovesItBack() throws {
        try withTwoDirs { src, dst in
            try Data("x".utf8).write(to: src.appendingPathComponent("m.txt"))
            let outcome = FileOperations.move(["m.txt"], from: src, to: dst)
            #expect(exists(dst.appendingPathComponent("m.txt")))

            let undo = FileOperations.undo(outcome.performed)
            #expect(undo.failures.isEmpty)
            #expect(exists(src.appendingPathComponent("m.txt")))
            #expect(!exists(dst.appendingPathComponent("m.txt")))
        }
    }

    @Test func undoCopyTrashesTheCopy() throws {
        try withTwoDirs { src, dst in
            try Data("x".utf8).write(to: src.appendingPathComponent("c.txt"))
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst)
            #expect(exists(dst.appendingPathComponent("c.txt")))

            let undo = FileOperations.undo(outcome.performed)
            #expect(undo.failures.isEmpty)
            #expect(!exists(dst.appendingPathComponent("c.txt")))  // moved to Trash
            #expect(exists(src.appendingPathComponent("c.txt")))  // original kept
        }
    }

    @Test func pasteCopyFromArbitrarySourceURLs() throws {
        try withTwoDirs { src, dst in
            try Data("x".utf8).write(to: src.appendingPathComponent("a.txt"))
            let outcome = FileOperations.copy(urls: [src.appendingPathComponent("a.txt")], into: dst)
            #expect(outcome.failures.isEmpty)
            #expect(exists(dst.appendingPathComponent("a.txt")))
            #expect(exists(src.appendingPathComponent("a.txt")))
        }
    }

    @Test func pasteMoveFromArbitrarySourceURLs() throws {
        try withTwoDirs { src, dst in
            try Data().write(to: src.appendingPathComponent("m.txt"))
            let outcome = FileOperations.move(urls: [src.appendingPathComponent("m.txt")], into: dst)
            #expect(outcome.performed.count == 1)
            #expect(exists(dst.appendingPathComponent("m.txt")))
            #expect(!exists(src.appendingPathComponent("m.txt")))
        }
    }

    @Test func conflictsByURLDetectsExisting() throws {
        try withTwoDirs { src, dst in
            try Data().write(to: src.appendingPathComponent("c.txt"))
            try Data().write(to: dst.appendingPathComponent("c.txt"))
            let found = FileOperations.conflicts(urls: [src.appendingPathComponent("c.txt")], into: dst)
            #expect(found == ["c.txt"])
        }
    }
}
