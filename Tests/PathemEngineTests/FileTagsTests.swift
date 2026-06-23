import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileTagsTests {
    /// A real temp file we can hang xattrs on.
    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-tags-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func untaggedFileHasNoTags() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileTags.tags(of: url).isEmpty)
    }

    @Test func setAndReadRoundTrips() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tags = [FileTag(color: .red), FileTag(name: "Work", color: .none), FileTag(color: .blue)]
        try FileTags.setTags(tags, on: url)
        let read = FileTags.tags(of: url)
        #expect(read == tags)
    }

    @Test func emptyArrayRemovesTheAttribute() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileTags.setTags([FileTag(color: .green)], on: url)
        #expect(!FileTags.tags(of: url).isEmpty)
        try FileTags.setTags([], on: url)  // must not throw even though it now removes
        #expect(FileTags.tags(of: url).isEmpty)
        try FileTags.setTags([], on: url)  // removing again (ENOATTR) is a no-op
    }

    @Test func toggleAddsThenRemoves() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileTags.toggleColor(.orange, on: url)
        #expect(FileTags.tags(of: url).contains(FileTag(color: .orange)))
        try FileTags.toggleColor(.orange, on: url)
        #expect(!FileTags.tags(of: url).contains(FileTag(color: .orange)))
    }

    @Test func tagsAttachToSymlinkNotTarget() throws {
        let target = try tempFile()
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try FileTags.setTags([FileTag(color: .blue)], on: link)
        #expect(FileTags.tags(of: link) == [FileTag(color: .blue)])
        #expect(FileTags.tags(of: target).isEmpty)  // the link's target must be untouched
    }

    @Test func usesFinderWireFormat() {
        // "Name\nColorIndex"; a plain name means no color.
        #expect(FileTags.format(FileTag(color: .red)) == "Red\n6")
        #expect(FileTags.format(FileTag(name: "Work")) == "Work")
        #expect(FileTags.parse("Red\n6") == FileTag(name: "Red", color: .red))
        #expect(FileTags.parse("Work") == FileTag(name: "Work", color: .none))
    }
}
