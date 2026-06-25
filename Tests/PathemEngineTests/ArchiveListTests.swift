import Foundation
import Testing

@testable import PathemEngine

@Suite struct ArchiveListTests {
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
