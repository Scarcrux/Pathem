import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileOpsUndoSafetyTests {
    private func fixture(_ body: (URL, URL, URL, String) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-undo-safety-\(UUID())")
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let dest = root.appendingPathComponent("dest")
        for dir in [a, b, dest] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        try body(a, b, dest, "safety-\(UUID()).txt")
    }

    @Test(arguments: [FileOperations.Action.copied, .moved])
    func dependentReplaceUndoPreservesIdentityAndRedoOrder(action: FileOperations.Action) throws {
        try fixture { a, b, dest, name in
            let first = a.appendingPathComponent(name)
            let second = b.appendingPathComponent(name)
            let target = dest.appendingPathComponent(name)
            try Data("A".utf8).write(to: first)
            try Data("B".utf8).write(to: second)
            try Data("ORIGINAL".utf8).write(to: target)
            let applied =
                action == .moved
                ? FileOperations.move(urls: [first, second], into: dest, onConflict: .replace)
                : FileOperations.copy(urls: [first, second], into: dest, onConflict: .replace)
            #expect(applied.performed.count == 2 && applied.failures.isEmpty)
            let undone = FileOperations.undo(applied.performed)
            #expect(undone.failures.isEmpty)
            #expect(try Data(contentsOf: first) == Data("A".utf8))
            #expect(try Data(contentsOf: second) == Data("B".utf8))
            #expect(try Data(contentsOf: target) == Data("ORIGINAL".utf8))
            // The return value is still in forward order, ready for a caller's Redo.
            #expect(undone.performed.map(\.source) == [first, second])
            let redone = FileOperations.redo(undone.performed)
            #expect(redone.failures.isEmpty && redone.performed.count == 2)
            #expect(try Data(contentsOf: target) == Data("B".utf8))
            let undoneAgain = FileOperations.undo(redone.performed)
            #expect(undoneAgain.failures.isEmpty)
            #expect(try Data(contentsOf: first) == Data("A".utf8))
            #expect(try Data(contentsOf: second) == Data("B".utf8))
            #expect(try Data(contentsOf: target) == Data("ORIGINAL".utf8))
        }
    }

    @Test(arguments: [FileOperations.Action.copied, .moved])
    func failedReplaceRedoRestoresDestination(action: FileOperations.Action) throws {
        try fixture { a, _, dest, name in
            let source = a.appendingPathComponent(name)
            let target = dest.appendingPathComponent(name)
            try Data("NEW".utf8).write(to: source)
            try Data("ORIGINAL".utf8).write(to: target)
            let applied =
                action == .moved
                ? FileOperations.move(urls: [source], into: dest, onConflict: .replace)
                : FileOperations.copy(urls: [source], into: dest, onConflict: .replace)
            let undone = FileOperations.undo(applied.performed)
            #expect(undone.failures.isEmpty)
            try FileManager.default.removeItem(at: source)
            let redone = FileOperations.redo(undone.performed)
            #expect(redone.performed.isEmpty && redone.failures.count == 1)
            #expect(try Data(contentsOf: target) == Data("ORIGINAL".utf8))
        }
    }

    @Test func failedNewerUndoDoesNotUndoAnOlderReplaceAtTheSameDestination() throws {
        try fixture { a, b, dest, name in
            let first = a.appendingPathComponent(name)
            let second = b.appendingPathComponent(name)
            let target = dest.appendingPathComponent(name)
            try Data("A".utf8).write(to: first)
            try Data("B".utf8).write(to: second)
            let applied = FileOperations.move(
                urls: [first, second], into: dest, onConflict: .replace)
            try Data("UNRELATED".utf8).write(to: second)
            let undone = FileOperations.undo(applied.performed)
            #expect(undone.performed.isEmpty && undone.failures.count == 2)
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(try Data(contentsOf: second) == Data("UNRELATED".utf8))
            #expect(try Data(contentsOf: target) == Data("B".utf8))
            // A remains recoverable in the recorded Trash location, not confused with B.
            #expect(
                try Data(contentsOf: #require(applied.performed.last?.replacedOriginalTrashed))
                    == Data("A".utf8))
        }
    }
}
