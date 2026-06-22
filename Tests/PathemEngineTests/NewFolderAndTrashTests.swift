import Foundation
import Testing

@testable import PathemEngine

@Suite struct NewFolderAndTrashTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-newfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func makeFolderPicksUniqueNames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try FileOperations.makeFolder(in: dir)
        #expect(first == "untitled folder")
        let second = try FileOperations.makeFolder(in: dir)
        #expect(second == "untitled folder 2")
        let third = try FileOperations.makeFolder(in: dir)
        #expect(third == "untitled folder 3")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("untitled folder 2").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func renameMovesAndRefusesClobber() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.txt"))
        try "b".data(using: .utf8)!.write(to: dir.appendingPathComponent("b.txt"))

        try FileOperations.rename("a.txt", to: "c.txt", in: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))

        // No-op when unchanged or empty; throws when the target exists.
        try FileOperations.rename("c.txt", to: "c.txt", in: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.txt").path))
        #expect(throws: (any Error).self) {
            try FileOperations.rename("c.txt", to: "b.txt", in: dir)
        }
    }

    @Test func trashThenUntrashRestores() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doomed.txt")
        try "x".data(using: .utf8)!.write(to: file)

        let (trashed, failures) = FileOperations.trash(["doomed.txt"], in: dir)
        #expect(failures.isEmpty)
        #expect(trashed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let undoFailures = FileOperations.untrash(trashed)
        #expect(undoFailures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
