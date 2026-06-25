import Foundation
import Testing

@testable import PathemEngine

@Suite struct ArchiveRepackTests {
    @Test func snapshotDetectsChanges() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "a".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.txt"))
        let before = Archiver.snapshot(of: dir)
        try "longer content".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.txt"))
        let after = Archiver.snapshot(of: dir)
        #expect(before != after)  // size changed
    }

    @Test func repackWritesChangesBackAndReExtracts() async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/tar") else { return }
        let base = fm.temporaryDirectory.appendingPathComponent("pathem-repack-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("payload"), withIntermediateDirectories: true)
        try "original".data(using: .utf8)!.write(to: base.appendingPathComponent("payload/file.txt"))
        defer { try? fm.removeItem(at: base) }

        // Make an archive.
        let archive = base.appendingPathComponent("bundle.tar.gz")
        _ = try await RemoteRunner.run("/usr/bin/tar", ["-czf", archive.path, "-C", base.path, "payload"])

        // Extract (mount), modify, add a file, then repack.
        let mount = base.appendingPathComponent("mount")
        try await Archiver.extract(archive, to: mount)
        try "edited".data(using: .utf8)!.write(to: mount.appendingPathComponent("payload/file.txt"))
        try "new".data(using: .utf8)!.write(to: mount.appendingPathComponent("payload/added.txt"))
        try await Archiver.repack(from: mount, into: archive)

        // Re-extract fresh and confirm the changes persisted in the archive.
        let verify = base.appendingPathComponent("verify")
        try await Archiver.extract(archive, to: verify)
        #expect((try? String(contentsOf: verify.appendingPathComponent("payload/file.txt"), encoding: .utf8)) == "edited")
        #expect(fm.fileExists(atPath: verify.appendingPathComponent("payload/added.txt").path))
    }
}
