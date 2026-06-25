import Foundation
import Testing

@testable import PathemEngine

@Suite struct ArchiveListTests {
    @Test func extractableAndRepackableFormats() {
        #expect(!Archiver.canExtract(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/tmp/a.tar.gz")))
        // 7z and rar read natively via libarchive.
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/tmp/a.7z")))
        #expect(Archiver.canExtract(URL(fileURLWithPath: "/tmp/a.rar")))
        // ...but rar can't be written back (libarchive is read-only for RAR).
        #expect(Archiver.canRepack(URL(fileURLWithPath: "/tmp/a.7z")))
        #expect(!Archiver.canRepack(URL(fileURLWithPath: "/tmp/a.rar")))
    }

    // 7z create/extract round-trip via the system tar (libarchive) — no third-party tool.
    @Test func sevenZipRoundTripNatively() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-7z-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hello.txt")
        try Data("hi there".utf8).write(to: file)
        let archive = dir.appendingPathComponent("out.7z")
        try await Archiver.compress7z([file], to: archive)
        #expect(fm.fileExists(atPath: archive.path))
        let listed = try await Archiver.list(archive)
        #expect(listed.contains { $0.hasSuffix("hello.txt") })
        let out = dir.appendingPathComponent("out")
        try await Archiver.extract(archive, to: out)
        #expect(try String(contentsOf: out.appendingPathComponent("hello.txt"), encoding: .utf8) == "hi there")
    }

    @Test func topLevelDerivesFoldersAndFiles() {
        let paths = [
            "README.md",
            "src/",
            "src/main.swift",
            "src/util/helper.swift",
            "./LICENSE",  // leading ./ tolerated
        ]
        let top = Archiver.topLevel(paths)
        let byName = Dictionary(uniqueKeysWithValues: top.map { ($0.name, $0.isDirectory) })
        #expect(byName["README.md"] == false)
        #expect(byName["src"] == true)
        #expect(byName["LICENSE"] == false)
        #expect(top.count == 3)  // README.md, src, LICENSE (deduped)
    }

    @Test func roundTripsThroughRealTar() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-arc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("payload/sub"), withIntermediateDirectories: true)
        try "x".data(using: .utf8)!.write(to: dir.appendingPathComponent("payload/a.txt"))
        try "y".data(using: .utf8)!.write(to: dir.appendingPathComponent("payload/sub/b.txt"))
        defer { try? fm.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("payload.tar")
        guard fm.isExecutableFile(atPath: "/usr/bin/tar") else { return }
        _ = try await RemoteRunner.run("/usr/bin/tar", ["-cf", archive.path, "-C", dir.path, "payload"])

        let paths = try await Archiver.list(archive)
        #expect(paths.contains { $0.hasSuffix("a.txt") })
        #expect(paths.contains { $0.hasSuffix("b.txt") })
        #expect(Archiver.topLevel(paths).contains { $0.name == "payload" && $0.isDirectory })
    }
}
