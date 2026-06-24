import Foundation
import Testing

@testable import PathemEngine

@Suite struct ArchiverTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-arc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func canExtractRecognizesExtensions() {
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/a/x.zip")))
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/a/x.tar.gz")))
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/a/x.tgz")))
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/a/x.txt")) == false)
    }

    @Test func zipRoundTripPreservesContent() async throws {
        let work = try tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        // Source items in one folder.
        let src = work.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: src.appendingPathComponent("nested/b.txt"))

        let zip = work.appendingPathComponent("out.zip")
        try await Archiver.compress([src], to: zip)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let out = work.appendingPathComponent("out", isDirectory: true)
        try await Archiver.extract(zip, to: out)
        #expect(
            try String(contentsOf: out.appendingPathComponent("src/a.txt"), encoding: .utf8) == "hello")
        #expect(
            try String(contentsOf: out.appendingPathComponent("src/nested/b.txt"), encoding: .utf8) == "world")
    }
}
