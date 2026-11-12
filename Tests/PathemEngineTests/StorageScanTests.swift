import Foundation
import Testing

@testable import PathemEngine

@Suite struct StorageScanTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ bytes: Int, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    @Test func findsJunkAndDoesNotDescendIntoIt() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(1000, root.appendingPathComponent("node_modules/big/lib.js"))
        try write(10, root.appendingPathComponent(".DS_Store"))
        try write(10, root.appendingPathComponent("keep.txt"))

        let report = StorageScan.scan(root, largeThreshold: 1, oldMinSize: 1)
        #expect(report.junk.contains { $0.reason == "node_modules" && $0.isDirectory })
        #expect(report.junk.contains { $0.reason == ".DS_Store" })
        // node_modules contents are not listed individually (treated as one item).
        #expect(!report.large.contains { $0.path.contains("node_modules") })
        #expect(report.safeReclaimable >= 1000)
    }

    @Test func duplicatesIgnoreExcludedDirectories() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(2_000_000, root.appendingPathComponent("a.dat"))
        try write(2_000_000, root.appendingPathComponent("copy/a.dat"))  // real duplicate
        try write(2_000_000, root.appendingPathComponent("node_modules/lib/a.dat"))  // noise
        try write(2_000_000, root.appendingPathComponent(".git/objects/a.dat"))  // noise

        let dups = StorageScan.duplicates(root)
        // Only the two real copies count; the node_modules/.git copies are excluded.
        #expect(dups.count == 1)
        #expect(!dups.contains { $0.path.contains("node_modules") || $0.path.contains(".git") })
    }

    @Test func surfacesLargeOldAndDuplicates() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Distinct sizes so only the intended pair are byte-identical (equal-size
        // zero files would otherwise collide as duplicates).
        try write(2_000_000, root.appendingPathComponent("huge.bin"))
        try write(3_000_000, root.appendingPathComponent("a.dat"))
        try write(3_000_000, root.appendingPathComponent("copy/a.dat"))  // duplicate of a.dat
        let oldFile = root.appendingPathComponent("ancient.bin")
        try write(2_500_000, oldFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -400 * 86_400)],
            ofItemAtPath: oldFile.path)

        let report = StorageScan.scan(root, largeThreshold: 1_000_000, oldMinSize: 1_000_000)
        #expect(report.large.contains { $0.path.hasSuffix("huge.bin") })
        #expect(report.old.contains { $0.path.hasSuffix("ancient.bin") })
        #expect(report.duplicates.count == 1)  // one extra copy of a.dat
        #expect(report.duplicates.first?.size == 3_000_000)
    }

    @Test func walksPastTheOldCutoffAndListsCaches() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 { try write(10, root.appendingPathComponent("a/f\(index).txt")) }
        try write(5000, root.appendingPathComponent("z/deep/.build/out.o"))
        try write(700, root.appendingPathComponent("z/Caches/blob"))
        // Control: with a limit, the walk stops early and says so.
        let limited = StorageScan.scanQuick(root, maxItems: 10)
        #expect(limited.truncated)
        // Default: no cutoff, everything found, not marked partial.
        let full = StorageScan.scanQuick(root)
        #expect(!full.truncated)
        #expect(full.junk.contains { $0.reason == ".build" && $0.size == 5000 })
        #expect(full.caches.map(\.size) == [700])
        #expect(full.caches.first?.category == .cache)
        #expect(full.filesScanned == 40)
        #expect(!full.large.contains { $0.path.contains("Caches") })
    }

    @Test func reportsProgressAndStopsWhenCancelled() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<6000 {
            try write(1, root.appendingPathComponent("d\(index % 3)/f\(index)"))
        }
        var ticks: [Int] = []
        let full = StorageScan.scanQuick(root, progress: { ticks.append($0) })
        #expect(ticks == [5000] && !full.truncated && full.filesScanned == 6000)
        let stopped = StorageScan.scanQuick(root, isCancelled: { true })
        #expect(stopped.truncated && stopped.filesScanned == 0)
    }

    @Test func groupsSmallItemsPerKindBiggestFirst() {
        func item(_ kind: String, _ size: Int64, _ n: Int) -> StorageScan.Item {
            .init(
                path: "/x/\(n)/\(kind)", size: size, category: .junk, reason: kind,
                isDirectory: true)
        }
        let items =
            (0..<500).map { item("__pycache__", 10, $0) }
            + [item(".build", 9000, 600), item(".build", 20, 601), item("node_modules", 30, 602)]
        let groups = StorageScan.grouped(items, individualAtLeast: 1000)
        #expect(groups.map(\.kind) == [".build", "__pycache__", "node_modules", ".build"])
        #expect(groups.map(\.items.count) == [1, 500, 1, 1])
        #expect(groups.map(\.size) == [9000, 5000, 30, 20])
        #expect(groups.reduce(0) { $0 + $1.items.count } == items.count)
    }
}
