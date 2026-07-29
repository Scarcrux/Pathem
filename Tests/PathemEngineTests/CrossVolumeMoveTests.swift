import Foundation
import Testing

@testable import PathemEngine

/// The cross-volume move path is the single highest data-loss risk in the app: it physically
/// copies the file to another volume and then deletes the user's original. Same-volume moves are
/// just renames and are covered elsewhere; these tests exercise the copy-then-delete path (and its
/// rollback) against a real second volume, a RAM disk. Serialized so two RAM disks don't churn
/// diskutil concurrently.
@Suite(.serialized) struct CrossVolumeMoveTests {
    @Test func copiesThenDeletesSourceAcrossVolumes() throws {
        guard let ram = RAMDisk.make() else { return }  // environment forbids a RAM disk: skip, don't fail
        defer { ram.eject() }
        let srcDir = try tempDir()
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let src = srcDir.appendingPathComponent("data.bin")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })  // bigger than one copy buffer
        try payload.write(to: src)

        // The whole point: source and destination are genuinely different volumes, so the move
        // takes the copy-then-delete path, not a rename.
        #expect(!FileOperations.sameVolume(src, ram.mount.appendingPathComponent("data.bin")))

        let outcome = FileOperations.move(urls: [src], into: ram.mount)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.performed.count == 1)
        let landed = ram.mount.appendingPathComponent("data.bin")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect((try? Data(contentsOf: landed)) == payload)  // content copied verbatim
        #expect(!FileManager.default.fileExists(atPath: src.path))  // original physically removed
    }

    @Test func rollsBackWhenSourceCannotBeRemoved() throws {
        guard let ram = RAMDisk.make() else { return }
        defer { ram.eject() }
        let srcDir = try tempDir()
        defer {
            _ = chmod(srcDir.path, 0o700)  // restore write so cleanup can delete it
            try? FileManager.default.removeItem(at: srcDir)
        }
        let src = srcDir.appendingPathComponent("data.bin")
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: src)

        // Read-only parent: the copy still reads the source (r-x), but removeItem(source) can't
        // unlink it (no write on the parent), so the move must roll the landed copy back.
        #expect(chmod(srcDir.path, 0o500) == 0)
        let outcome = FileOperations.move(urls: [src], into: ram.mount)
        _ = chmod(srcDir.path, 0o700)

        #expect(outcome.failures.count == 1)  // reported as failed, not silently lost
        #expect(FileManager.default.fileExists(atPath: src.path))  // the original survived
        // The copy was rolled back, so there's no stray duplicate on the destination volume.
        #expect(!FileManager.default.fileExists(atPath: ram.mount.appendingPathComponent("data.bin").path))
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-xvol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A throwaway APFS RAM disk for cross-volume tests. `make()` returns nil when the environment
/// won't allow one (a restricted sandbox), so the test skips rather than fails.
private struct RAMDisk {
    let mount: URL
    let device: String

    static func make() -> RAMDisk? {
        // 64 MB = 131072 512-byte sectors; -nomount yields a raw /dev/diskN we then format.
        guard let device = run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://131072"])?
            .split(whereSeparator: { $0 == "\n" || $0 == " " }).first.map(String.init),
            device.hasPrefix("/dev/disk")
        else { return nil }
        let name = "PathemXVol\(UUID().uuidString.prefix(8))"
        guard run("/usr/sbin/diskutil", ["eraseVolume", "APFS", name, device]) != nil else {
            _ = run("/usr/sbin/diskutil", ["eject", device])
            return nil
        }
        let mount = URL(fileURLWithPath: "/Volumes/\(name)")
        guard FileManager.default.fileExists(atPath: mount.path) else {
            _ = run("/usr/sbin/diskutil", ["eject", device])
            return nil
        }
        return RAMDisk(mount: mount, device: device)
    }

    func eject() { _ = RAMDisk.run("/usr/sbin/diskutil", ["eject", device]) }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
