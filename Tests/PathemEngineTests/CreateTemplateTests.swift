import Foundation
import Testing

@testable import PathemEngine

@Suite struct CreateTemplateTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-tmpl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func instantiatesTreeOfFilesAndFolders() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = CreateTemplate(
            id: "p", name: "Project", entries: ["src/", "src/main.swift", "tests/", "README.md"])
        let result = template.instantiate(in: dir)
        #expect(result.failures.isEmpty)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("src").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("src/main.swift").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("README.md").path))
        #expect(Set(result.created) == ["src", "tests", "README.md"])  // top-level only
    }

    @Test func doesNotReportPreexistingTopLevelAsCreated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let template = CreateTemplate(id: "p", name: "P", entries: ["src/new.swift", "docs/"])
        let result = template.instantiate(in: dir)
        // src/ existed, so undo must not trash it; only "docs" is newly introduced.
        #expect(result.created == ["docs"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("src/new.swift").path))
    }

    @Test func rejectsUnsafePaths() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = CreateTemplate(id: "x", name: "X", entries: ["../escape", "/abs", "ok.txt"])
        let result = template.instantiate(in: dir)
        #expect(result.created == ["ok.txt"])
        #expect(result.failures.count == 2)
    }
}
