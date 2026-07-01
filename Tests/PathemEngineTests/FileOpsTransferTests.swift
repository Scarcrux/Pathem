import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileOpsTransferTests {
    private final class Box { var seen = 0 }

    private func makePair(count: Int) throws -> (src: URL, dst: URL, urls: [URL]) {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("pathem-tx-src-\(UUID().uuidString)")
        let dst = fm.temporaryDirectory.appendingPathComponent("pathem-tx-dst-\(UUID().uuidString)")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let urls = try (1...count).map { i -> URL in
            let url = src.appendingPathComponent("f\(i).txt")
            try "x".data(using: .utf8)!.write(to: url)
            return url
        }
        return (src, dst, urls)
    }

    @Test func copyReportsByteProgressForEachItem() throws {
        let (src, dst, urls) = try makePair(count: 3)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        var reports: [FileOperations.Progress] = []
        let outcome = FileOperations.copy(urls: urls, into: dst, onConflict: .skip, report: { reports.append($0) })
        #expect(outcome.performed.count == 3)
        // Each file holds one byte, so totals are known exactly.
        #expect(reports.first?.totalBytes == 3)
        #expect(reports.first?.totalItems == 3)
        #expect(reports.last?.completedItems == 3)
        #expect(reports.last?.completedBytes == 3)
        // The current file is named before each item is copied.
        #expect(reports.contains { $0.currentFile == "f2.txt" })
    }

    @Test func copyStopsWhenCancelled() throws {
        let (src, dst, urls) = try makePair(count: 5)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let box = Box()
        // Cancel once two items have completed.
        let outcome = FileOperations.copy(
            urls: urls, into: dst, onConflict: .skip,
            shouldCancel: { box.seen >= 2 }, report: { box.seen = $0.completedItems })
        #expect(outcome.performed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("f3.txt").path))
    }

    @Test func totalBytesRecursesIntoFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-bytes-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 250).write(to: sub.appendingPathComponent("b.bin"))
        #expect(FileOperations.totalBytes(of: [root]) == 350)
    }
}
