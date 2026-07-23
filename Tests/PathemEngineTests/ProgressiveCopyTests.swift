import Foundation
import Testing

@testable import PathemEngine

/// Covers the streaming copy that powers the transfer bar's live speed/ETA: it must
/// report bytes *as they flow* (not just at the end), copy content + metadata faithfully,
/// and abort cleanly without leaving a half-written file.
@Suite struct ProgressiveCopyTests {
    private func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-pc-\(UUID().uuidString).bin")
        // Non-trivial content so a content compare is meaningful.
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 4096) { data[i] = UInt8(i & 0xFF) }
        try data.write(to: url)
        return url
    }

    @Test func reportsStreamingBytesForALargeFile() throws {
        let size = 16 * 1024 * 1024  // big enough that copyfile emits several data callbacks
        let src = try tempFile(bytes: size)
        let dst = src.deletingLastPathComponent().appendingPathComponent("pc-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        var samples: [Int64] = []
        try ProgressiveCopy.copy(from: src, to: dst, onBytes: { samples.append($0) })

        #expect(FileManager.default.contentsEqual(atPath: src.path, andPath: dst.path))
        #expect(samples.last == Int64(size))  // finishes at exactly the file size
        // The whole point: at least one report lands mid-file, so the bar animates.
        #expect(samples.contains { $0 > 0 && $0 < Int64(size) })
        // Byte counts only ever move forward.
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellingMidCopyThrowsAndRemovesThePartialFile() throws {
        let size = 16 * 1024 * 1024
        let src = try tempFile(bytes: size)
        let dst = src.deletingLastPathComponent().appendingPathComponent("pc-cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        final class Flag { var cancel = false }
        let flag = Flag()
        var threwCancelled = false
        do {
            try ProgressiveCopy.copy(
                from: src, to: dst,
                onBytes: { bytes in if bytes > 0 { flag.cancel = true } },  // cancel after first progress
                shouldCancel: { flag.cancel })
        } catch is ProgressiveCopy.Cancelled {
            threwCancelled = true
        }
        #expect(threwCancelled)
        #expect(!FileManager.default.fileExists(atPath: dst.path))  // no corrupt leftover
    }

    @Test func preservesPosixMode() throws {
        let src = try tempFile(bytes: 2048)
        let dst = src.deletingLastPathComponent().appendingPathComponent("pc-mode-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: src.path)

        try ProgressiveCopy.copy(from: src, to: dst, onBytes: { _ in })

        let mode = try FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o640)
    }

    @Test func copiesADirectoryTreeRecursively() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-pc-tree-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let dst = fm.temporaryDirectory.appendingPathComponent("pathem-pc-tree-out-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: dst) }
        try Data(repeating: 1, count: 200).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 300).write(to: sub.appendingPathComponent("b.bin"))

        var last: Int64 = 0
        try ProgressiveCopy.copy(from: root, to: dst, onBytes: { last = $0 })

        #expect(fm.fileExists(atPath: dst.appendingPathComponent("a.bin").path))
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("sub/b.bin").path))
        #expect(last == 500)  // both files' bytes, accumulated across the tree
    }

    @Test func sameVolumeIsTrueWithinOneVolume() throws {
        // Volume lookup needs the source file (and the dest's parent folder) to exist, which is
        // always true for a real move: the item being moved exists, so does its destination folder.
        let src = try tempFile(bytes: 8)
        defer { try? FileManager.default.removeItem(at: src) }
        let dest = src.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString).bin")
        #expect(FileOperations.sameVolume(src, dest))
    }
}
