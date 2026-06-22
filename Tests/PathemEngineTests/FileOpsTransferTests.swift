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

    @Test func copyReportsProgressForEachItem() throws {
        let (src, dst, urls) = try makePair(count: 3)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        var ticks: [Int] = []
        let outcome = FileOperations.copy(urls: urls, into: dst, onConflict: .skip, progress: { ticks.append($0) })
        #expect(outcome.performed.count == 3)
        #expect(ticks == [1, 2, 3])
    }

    @Test func copyStopsWhenCancelled() throws {
        let (src, dst, urls) = try makePair(count: 5)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let box = Box()
        // Cancel once two items have completed.
        let outcome = FileOperations.copy(
            urls: urls, into: dst, onConflict: .skip,
            shouldCancel: { box.seen >= 2 }, progress: { box.seen = $0 })
        #expect(outcome.performed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("f3.txt").path))
    }
}
