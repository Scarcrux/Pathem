import Foundation
import Testing

@testable import PathemEngine

@Suite struct BatchCreateTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-bc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func expandsPaddedRange() {
        #expect(BatchCreate.expand("Chapter {01..12}").first == "Chapter 01")
        #expect(BatchCreate.expand("Chapter {01..12}").count == 12)
        #expect(BatchCreate.expand("Chapter {01..12}").last == "Chapter 12")
        #expect(BatchCreate.expand("shot_{1..3}") == ["shot_1", "shot_2", "shot_3"])
    }

    @Test func expandsListAndDedupes() {
        let names = BatchCreate.expand("a.txt\n b.txt \n\na.txt\nc.txt")
        #expect(names == ["a.txt", "b.txt", "c.txt"])  // trimmed, blank dropped, deduped
    }

    @Test func mixesListAndPatternsAndDescends() {
        let names = BatchCreate.expand("README.md\nq{3..1}")
        #expect(names == ["README.md", "q3", "q2", "q1"])  // descending range
    }

    @Test func dropsInvalidNames() {
        #expect(BatchCreate.expand("../etc\nok\na/b\n.") == ["ok"])
    }

    @Test func createMakesItemsAndSkipsExisting() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("b.txt"))  // pre-existing

        let result = BatchCreate.create(["a.txt", "b.txt", "c.txt"], kind: .files, in: dir)
        #expect(result.created == ["a.txt", "c.txt"])  // b.txt skipped (no clobber)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    }

    @Test func makeFileUniquifiesBeforeExtension() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try FileOperations.makeFile(in: dir, baseName: "note.txt")
        let second = try FileOperations.makeFile(in: dir, baseName: "note.txt")
        #expect(first == "note.txt")
        #expect(second == "note 2.txt")  // number inserted before the extension
    }
}
