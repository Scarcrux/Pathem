import Foundation
import Testing

@testable import PathemEngine

@Suite struct FolderCompareTests {
    private func dir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func kind(_ diffs: [FolderCompare.Difference], _ rel: String) -> FolderCompare.DiffKind? {
        diffs.first { $0.relativePath == rel }?.kind
    }

    @Test func mirrorPlanItemizesCopiesAndDeletes() {
        let diffs = [
            FolderCompare.Difference(relativePath: "keep.txt", kind: .identical),
            FolderCompare.Difference(relativePath: "new.txt", kind: .onlyLeft),
            FolderCompare.Difference(relativePath: "changed.txt", kind: .differs),
            FolderCompare.Difference(relativePath: "extra.txt", kind: .onlyRight),
        ]
        // Deleting extras: copy the new + changed, delete the target-only file.
        let withDelete = FolderCompare.mirrorPlan(diffs, deleteExtras: true)
        #expect(withDelete.copies.sorted() == ["changed.txt", "new.txt"])
        #expect(withDelete.deletes == ["extra.txt"])
        // Additive: same copies, but nothing is deleted.
        let additive = FolderCompare.mirrorPlan(diffs, deleteExtras: false)
        #expect(additive.copies.sorted() == ["changed.txt", "new.txt"])
        #expect(additive.deletes.isEmpty)
    }

    @Test func classifiesByRelativePath() throws {
        let left = try dir(), right = try dir()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write("x", left.appendingPathComponent("same.txt"))
        try write("x", right.appendingPathComponent("same.txt"))
        try write("aaa", left.appendingPathComponent("sub/diff.txt"))
        try write("bbbb", right.appendingPathComponent("sub/diff.txt"))  // different size
        try write("l", left.appendingPathComponent("leftonly.txt"))
        try write("r", right.appendingPathComponent("rightonly.txt"))

        let diffs = FolderCompare.compare(left: left, right: right, byContent: true)
        #expect(kind(diffs, "same.txt") == .identical)
        #expect(kind(diffs, "sub/diff.txt") == .differs)
        #expect(kind(diffs, "leftonly.txt") == .onlyLeft)
        #expect(kind(diffs, "rightonly.txt") == .onlyRight)
    }

    @Test func mirrorCopiesMissingAndDiffering() throws {
        let left = try dir(), right = try dir()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write("new", left.appendingPathComponent("a/new.txt"))
        try write("v2", left.appendingPathComponent("changed.txt"))
        try write("v1-longer", right.appendingPathComponent("changed.txt"))

        let diffs = FolderCompare.compare(left: left, right: right)
        let result = FolderCompare.mirror(from: left, to: right, differences: diffs, deleteExtras: false)
        #expect(result.failures.isEmpty)
        #expect(result.copied == 2)
        #expect(
            try String(contentsOf: right.appendingPathComponent("a/new.txt"), encoding: .utf8) == "new")
        #expect(
            try String(contentsOf: right.appendingPathComponent("changed.txt"), encoding: .utf8) == "v2")
    }

    @Test func mirrorRefusesToDeleteADirectoryForAFile() throws {
        let left = try dir(), right = try dir()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write("i am a file", left.appendingPathComponent("report"))  // left: FILE named report
        try write("precious", right.appendingPathComponent("report/important.txt"))  // right: DIR named report

        let diffs = FolderCompare.compare(left: left, right: right)
        let result = FolderCompare.mirror(from: left, to: right, differences: diffs, deleteExtras: false)
        // The clashing item is reported, and the right-side directory is NOT destroyed.
        #expect(result.failures.contains("report"))
        #expect(
            try String(contentsOf: right.appendingPathComponent("report/important.txt"), encoding: .utf8)
                == "precious")
    }

    @Test func mirrorDeleteExtrasTrashesRightOnly() throws {
        let left = try dir(), right = try dir()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write("keep", left.appendingPathComponent("keep.txt"))
        try write("keep", right.appendingPathComponent("keep.txt"))
        try write("extra", right.appendingPathComponent("extra.txt"))

        let diffs = FolderCompare.compare(left: left, right: right)
        let result = FolderCompare.mirror(from: left, to: right, differences: diffs, deleteExtras: true)
        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: right.appendingPathComponent("extra.txt").path))
    }
}
