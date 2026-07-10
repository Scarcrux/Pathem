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

    @Test func compressItemsGathersFilesFromDifferentFolders() async throws {
        let work = try tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        // Two files in two SEPARATE folders (the cross-pane drag case) -- plain compress would only
        // catch the first item's folder; compressItems must stage both.
        let f1 = work.appendingPathComponent("one", isDirectory: true)
        let f2 = work.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: f1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f2, withIntermediateDirectories: true)
        let a = f1.appendingPathComponent("a.txt"), b = f2.appendingPathComponent("b.txt")
        try Data("aaa".utf8).write(to: a)
        try Data("bbb".utf8).write(to: b)

        let zip = work.appendingPathComponent("both.zip")
        try await Archiver.compressItems([a, b], to: zip)

        let out = work.appendingPathComponent("out", isDirectory: true)
        try await Archiver.extract(zip, to: out)
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "aaa")
        #expect(try String(contentsOf: out.appendingPathComponent("b.txt"), encoding: .utf8) == "bbb")
    }
}
