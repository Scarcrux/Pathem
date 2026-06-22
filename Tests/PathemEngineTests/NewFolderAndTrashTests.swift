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
