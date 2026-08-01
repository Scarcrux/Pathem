import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileOperationsTests {
    private func withTwoDirs(_ body: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-fileops-\(UUID().uuidString)")
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

    @Test func refusesToCopyFolderIntoItsOwnSubtree() throws {
        try withTwoDirs { src, _ in
            // A folder "A" with a subfolder; copy A into A/sub must be refused, not recurse.
            let a = src.appendingPathComponent("A")
            let sub = a.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: a.appendingPathComponent("f.txt"))
            let outcome = FileOperations.copy(urls: [a], into: sub)
            #expect(outcome.performed.isEmpty)
            #expect(outcome.failures.count == 1)
            #expect(!exists(sub.appendingPathComponent("A")))  // nothing nested
        }
    }

    @Test func failedReplaceRestoresTheOverwrittenFile() throws {
        try withTwoDirs { src, dst in
            // Destination has a file; replacing it with a directory-shaped source that fails the
            // op must leave the original destination file intact, not stranded in the Trash.
            try Data("original".utf8).write(to: dst.appendingPathComponent("x"))
            // Source "x" is a nonexistent path so copyItem throws after the destination is trashed.
            let ghost = src.appendingPathComponent("x")  // does not exist
            let outcome = FileOperations.copy(urls: [ghost], into: dst, onConflict: .replace)
            #expect(outcome.performed.isEmpty)
            #expect(outcome.failures.count == 1)
            let restored = dst.appendingPathComponent("x")
            #expect(exists(restored))
            #expect((try? Data(contentsOf: restored)) == Data("original".utf8))
        }
    }

    @Test func isDescendantCatchesNestedAndEqualPaths() {
        let base = URL(fileURLWithPath: "/tmp/A")
        #expect(FileOperations.isDescendant(URL(fileURLWithPath: "/tmp/A"), of: base))
        #expect(FileOperations.isDescendant(URL(fileURLWithPath: "/tmp/A/sub/A"), of: base))
        #expect(!FileOperations.isDescendant(URL(fileURLWithPath: "/tmp/B"), of: base))
        #expect(!FileOperations.isDescendant(URL(fileURLWithPath: "/tmp/AB"), of: base))  // prefix, not child
    }

    /// Dropping a file into its own folder, even with .replace, must skip it and
    /// never trash the source onto itself (the data-loss backstop).
    @Test func sameFolderReplaceSkipsAndKeepsSource() throws {
        try withTwoDirs { src, _ in
            let file = src.appendingPathComponent("self.txt")
            try Data("keep me".utf8).write(to: file)
            let outcome = FileOperations.copy(urls: [file], into: src, onConflict: .replace)
            #expect(outcome.performed.isEmpty)
            #expect(outcome.skipped == ["self.txt"])
            #expect(outcome.failures.isEmpty)
            #expect(exists(file))
            #expect(try Data(contentsOf: file) == Data("keep me".utf8))
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

    @Test func undoReplaceRestoresOverwrittenCopy() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst, onConflict: .replace)
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "new")

            let undo = FileOperations.undo(outcome.performed)
            #expect(undo.failures.isEmpty)
            // The overwritten original is restored, not stranded in the Trash.
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "old")
            #expect(exists(src.appendingPathComponent("c.txt")))
        }
    }

    @Test func undoReplaceMoveRestoresOverwrittenAndSource() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            let outcome = FileOperations.move(["c.txt"], from: src, to: dst, onConflict: .replace)

            let undo = FileOperations.undo(outcome.performed)
            #expect(undo.failures.isEmpty)
            #expect(try String(contentsOf: src.appendingPathComponent("c.txt"), encoding: .utf8) == "new")
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "old")
        }
    }

    @Test func intraBatchDuplicateBasenamesConflictEvenWhenDestEmpty() throws {
        try withTwoDirs { src, dst in
            let a = src.appendingPathComponent("a")
            let b = src.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            try Data("1".utf8).write(to: a.appendingPathComponent("photo.jpg"))
            try Data("2".utf8).write(to: b.appendingPathComponent("photo.jpg"))
            let urls = [a.appendingPathComponent("photo.jpg"), b.appendingPathComponent("photo.jpg")]
            // The destination has no photo.jpg, but the two sources collide with each other, so the
            // second must be flagged for resolution instead of silently overwriting the first.
            #expect(FileOperations.conflicts(urls: urls, into: dst) == ["photo.jpg"])
            // Unique names into an empty destination stay conflict-free.
            try Data().write(to: src.appendingPathComponent("x.txt"))
            try Data().write(to: src.appendingPathComponent("y.txt"))
            #expect(FileOperations.conflicts(
                urls: [src.appendingPathComponent("x.txt"), src.appendingPathComponent("y.txt")], into: dst).isEmpty)
        }
    }

    @Test func keepBothCopiesBothSameNamedSourcesInsteadOfDroppingOne() throws {
        try withTwoDirs { src, dst in
            let a = src.appendingPathComponent("a")
            let b = src.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            try Data("1".utf8).write(to: a.appendingPathComponent("photo.jpg"))
            try Data("2".utf8).write(to: b.appendingPathComponent("photo.jpg"))
            let urls = [a.appendingPathComponent("photo.jpg"), b.appendingPathComponent("photo.jpg")]
            let outcome = FileOperations.copy(urls: urls, into: dst, onConflict: .keepBoth)
            // Both land (one keeps the name, the other is auto-numbered); nothing is skipped.
            let landed = try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.hasSuffix(".jpg") }
            #expect(landed.count == 2)
            #expect(outcome.skipped.isEmpty)
        }
    }

    @Test func redoOfReplaceReappliesAndUndoStillRestoresTheOriginal() throws {
        try withTwoDirs { src, dst in
            try Data("new".utf8).write(to: src.appendingPathComponent("c.txt"))
            try Data("old".utf8).write(to: dst.appendingPathComponent("c.txt"))
            // Replace: dst/c.txt "old" -> "new", with "old" displaced to the Trash.
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst, onConflict: .replace)
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "new")

            // Undo restores "old".
            let undo = FileOperations.undo(outcome.performed)
            #expect(undo.failures.isEmpty)
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "old")

            // Redo re-applies the replace, re-trashing the restored "old" to a FRESH trash location
            // recorded in redo.performed.
            let redo = FileOperations.redo(undo.performed)
            #expect(redo.failures.isEmpty)
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "new")

            // The bit the code warns about: undoing the redo must restore "old" again, using the
            // fresh trash location redo recorded, not the stale original -- otherwise a later undo
            // trashes the wrong file.
            let undo2 = FileOperations.undo(redo.performed)
            #expect(undo2.failures.isEmpty)
            #expect(try String(contentsOf: dst.appendingPathComponent("c.txt"), encoding: .utf8) == "old")
        }
    }

    @Test func redoMoveReappliesAfterUndo() throws {
        try withTwoDirs { src, dst in
            try Data("x".utf8).write(to: src.appendingPathComponent("m.txt"))
            let outcome = FileOperations.move(["m.txt"], from: src, to: dst)
            let undo = FileOperations.undo(outcome.performed)
            #expect(exists(src.appendingPathComponent("m.txt")))

            let redo = FileOperations.redo(undo.performed)
            #expect(redo.failures.isEmpty)
            #expect(exists(dst.appendingPathComponent("m.txt")))  // back at destination
            #expect(!exists(src.appendingPathComponent("m.txt")))
        }
    }

    @Test func redoCopyReappliesAfterUndo() throws {
        try withTwoDirs { src, dst in
            try Data("x".utf8).write(to: src.appendingPathComponent("c.txt"))
            let outcome = FileOperations.copy(["c.txt"], from: src, to: dst)
            let undo = FileOperations.undo(outcome.performed)  // trashes the copy
            #expect(!exists(dst.appendingPathComponent("c.txt")))

            let redo = FileOperations.redo(undo.performed)
            #expect(redo.failures.isEmpty)
            #expect(exists(dst.appendingPathComponent("c.txt")))  // copy re-created
            #expect(exists(src.appendingPathComponent("c.txt")))  // source still there
        }
    }

    @Test func untrashRestoresUnderNewNameWhenOriginalReoccupied() throws {
        try withTwoDirs { dir, _ in
            let original = dir.appendingPathComponent("c.txt")
            try Data("old".utf8).write(to: original)
            let (trashed, failures) = FileOperations.trash(urls: [original])
            #expect(failures.isEmpty)
            #expect(trashed.count == 1)

            // Something reoccupies the original path before the undo.
            try Data("new".utf8).write(to: original)
            let undoFailures = FileOperations.untrash(trashed).failures

            // The trashed file comes back (under a new name) and the clash is reported,
            // instead of the undo silently failing and leaving it in the Trash.
            #expect(undoFailures.count == 1)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.count == 2)
            #expect(try String(contentsOf: original, encoding: .utf8) == "new")  // reoccupier untouched
            let restored = try #require(names.first { $0 != "c.txt" })
            #expect(try String(contentsOf: dir.appendingPathComponent(restored), encoding: .utf8) == "old")
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
