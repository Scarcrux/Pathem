import Foundation
import Testing

@testable import PathemEngine

@Suite struct BulkAttributesTests {
    private func tempFiles(_ count: Int) throws -> (dir: URL, files: [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-attr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try (0..<count).map { i -> URL in
            let url = dir.appendingPathComponent("f\(i).txt")
            try Data("x".utf8).write(to: url)
            return url
        }
        return (dir, files)
    }

    @Test func setsModificationDateAndPermissionsAcrossSelection() throws {
        let (dir, files) = try tempFiles(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        let result = BulkAttributes.apply(
            .init(modificationDate: when, posixPermissions: 0o600), to: files)
        #expect(result.changed == 3)
        #expect(result.failures.isEmpty)
        for file in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attrs[.modificationDate] as? Date) == when)
            #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        }
    }

    @Test func addsAndRemovesTags() throws {
        let (dir, files) = try tempFiles(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = files[0]
        _ = BulkAttributes.apply(.init(addTags: ["Work", "Urgent"]), to: [file])
        var tags = Set(FileTags.tags(of: file).map(\.name))
        #expect(tags.contains("Work"))
        #expect(tags.contains("Urgent"))

        _ = BulkAttributes.apply(.init(removeTags: ["Urgent"]), to: [file])
        tags = Set(FileTags.tags(of: file).map(\.name))
        #expect(tags.contains("Work"))
        #expect(!tags.contains("Urgent"))
    }

    @Test func emptyChangesDoNothing() throws {
        let (dir, files) = try tempFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = BulkAttributes.apply(.init(), to: files)
        #expect(result.changed == 0)
    }
}
