import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileSplitterTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func splitThenMergeRoundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 2500 bytes of varied content, split into 1000-byte parts => 1000 + 1000 + 500.
        let original = Data((0..<2500).map { UInt8($0 % 256) })
        let file = dir.appendingPathComponent("movie.mov")
        try original.write(to: file)

        let parts = try FileSplitter.split(file, partSize: 1000)
        #expect(parts.count == 3)
        #expect(parts.map(\.lastPathComponent) == ["movie.mov.001", "movie.mov.002", "movie.mov.003"])
        #expect(try Data(contentsOf: parts[2]).count == 500)

        // Merge to a fresh name (the original still exists, so it uniquifies).
        try FileManager.default.removeItem(at: file)
        let merged = try FileSplitter.merge(firstPart: parts[0])
        #expect(try Data(contentsOf: merged) == original)
    }

    @Test func exactMultipleHasNoEmptyTrailingPart() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.bin")
        try Data(repeating: 9, count: 2000).write(to: file)
        let parts = try FileSplitter.split(file, partSize: 1000)
        #expect(parts.count == 2)  // exactly 2, no empty .003
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("data.bin.003").path))
    }

    @Test func mergeRejectsNonPart() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notPart = dir.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: notPart)
        #expect(throws: FileSplitter.SplitError.notAPart) {
            try FileSplitter.merge(firstPart: notPart)
        }
    }

    @Test func invalidPartSizeThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: file)
        #expect(throws: FileSplitter.SplitError.invalidSize) {
            try FileSplitter.split(file, partSize: 0)
        }
    }
}
