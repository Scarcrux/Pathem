import Foundation
import Testing

@testable import PathemEngine

@Suite struct DirectorySizeTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-dirsize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sumsFilesRecursivelyIncludingHidden() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 100).write(to: root.appendingPathComponent("a.bin"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 200).write(to: sub.appendingPathComponent("b.bin"))
        try Data(count: 50).write(to: root.appendingPathComponent(".hidden"))  // must be counted

        let measure = DirectorySize.total(of: root)
        #expect(measure.bytes == 350)
        #expect(measure.complete)  // nothing was unreadable
    }

    @Test func emptyFolderIsZero() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let measure = DirectorySize.total(of: root)
        #expect(measure.bytes == 0)
        #expect(measure.complete)
    }

    @Test func unreadableSubtreeMarksResultIncomplete() throws {
        let root = try tempDir()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(count: 200).write(to: locked.appendingPathComponent("secret.bin"))
        // Make the subtree unreadable, then always restore so cleanup can delete it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let measure = DirectorySize.total(of: root)
        #expect(measure.complete == false)  // the locked subtree couldn't be read
        #expect(measure.bytes >= 100)  // still counts what it could reach (a lower bound)
        #expect(measure.bytes < 300)  // the locked file's bytes are not included
    }

    /// The parallel walk must agree with the original enumerator-based implementation.
    @Test func parallelWalkMatchesTheReferenceOnAMixedTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-ds-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var expected: Int64 = 0
        for index in 0..<300 {
            let dir = root.appendingPathComponent("d\(index % 7)/e\(index % 13)/f\(index % 3)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let size = (index * 37) % 5000
            try Data(count: size).write(
                to: dir.appendingPathComponent(index % 5 == 0 ? ".hidden\(index)" : "file\(index)"))
            expected += Int64(size)
        }
        try Data(count: 11).write(to: root.appendingPathComponent("top.bin"))
        expected += 11
        // A symlink to a big outside file and to a folder: neither is followed or counted.
        let outside = fm.temporaryDirectory.appendingPathComponent(
            "pathem-ds-out-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data(count: 99_999).write(to: outside.appendingPathComponent("big"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link-file"),
            withDestinationURL: outside.appendingPathComponent("big"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link-dir"), withDestinationURL: outside)

        let fast = DirectorySize.total(of: root)
        let reference = DirectorySize.referenceTotal(of: root)
        #expect(fast == reference)
        #expect(fast.bytes == expected && fast.complete)
        #expect(DirectorySize.total(of: root.appendingPathComponent("top.bin")).complete == false)
    }

    private func wideTree(folders: Int, filesEach: Int) throws -> (URL, Int64) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-ds-\(UUID().uuidString)")
        var expected: Int64 = 0
        for index in 0..<folders {
            let dir = root.appendingPathComponent("a\(index % 20)/b\(index % 50)/c\(index)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<filesEach {
                try Data(count: 7).write(to: dir.appendingPathComponent("f\(file)"))
                expected += 7
            }
        }
        return (root, expected)
    }

    /// A cancelled walk returns nil and stops reading folders; the same tree uncancelled is
    /// read in full (the control: without it "stopped early" could not be told from "small").
    @Test func cancelStopsTheWalkEarly() throws {
        let (root, expected) = try wideTree(folders: 3000, filesEach: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() -> Int {
                lock.withLock {
                    value += 1
                    return value
                }
            }
            var count: Int { lock.withLock { value } }
        }
        let full = Counter()
        let whole = DirectorySize.total(
            of: root,
            isCancelled: {
                _ = full.bump()
                return false
            })
        #expect(whole == DirectorySize.Measurement(bytes: expected, complete: true))
        #expect(full.count > 3000)

        let cut = Counter()
        let stopped = DirectorySize.total(of: root, isCancelled: { cut.bump() > 100 })
        #expect(stopped == nil)
        #expect(cut.count < full.count / 4, "asked \(cut.count) times of \(full.count)")
    }

    /// Six walks at once stay under one shared thread cap. Control: with the cap lifted the
    /// same six walks use more threads than the cap allows, so the counter can go red.
    @Test func concurrentWalksShareOneThreadCap() async throws {
        let pool = DirectorySize.WalkerPool.shared
        let normal = pool.limit
        defer { pool.limit = normal }
        var roots: [URL] = []
        var expected: Int64 = 0
        for _ in 0..<6 {
            let (root, bytes) = try wideTree(folders: 1500, filesEach: 1)
            roots.append(root)
            expected = bytes
        }
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        let all = roots
        @Sendable func runAll() async -> [Int64] {
            await withTaskGroup(of: Int64.self) { group in
                for root in all {
                    group.addTask {
                        await withCheckedContinuation { done in
                            Thread.detachNewThread {
                                done.resume(returning: DirectorySize.total(of: root).bytes)
                            }
                        }
                    }
                }
                var sizes: [Int64] = []
                for await size in group { sizes.append(size) }
                return sizes
            }
        }
        let cap = 3
        pool.limit = 1000
        pool.resetPeak()
        #expect(await runAll() == Array(repeating: expected, count: 6))
        let uncapped = pool.peak
        #expect(uncapped > cap, "control: uncapped peak \(uncapped)")

        pool.limit = cap
        pool.resetPeak()
        #expect(await runAll() == Array(repeating: expected, count: 6))
        #expect(pool.peak <= cap, "capped peak \(pool.peak)")
    }
}
