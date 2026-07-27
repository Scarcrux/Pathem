import Foundation
import Testing

@testable import PathemEngine

@Suite struct NearDuplicatePhotosTests {
    @Test func emptyAndNonImagesYieldNoGroups() throws {
        #expect(NearDuplicatePhotos.groups(of: []).isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-neardup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        // No feature prints for non-images, so no clusters (and no crash).
        #expect(NearDuplicatePhotos.groups(of: [a, b]).isEmpty)
    }

    @Test func groupExtrasExcludeTheKeeper() {
        let urls = [URL(fileURLWithPath: "/x/1.jpg"), URL(fileURLWithPath: "/x/2.jpg"), URL(fileURLWithPath: "/x/3.jpg")]
        let group = NearDuplicatePhotos.Group(urls: urls, keepIndex: 1)
        #expect(group.extras == [urls[0], urls[2]])
    }
}
