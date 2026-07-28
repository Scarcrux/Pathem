import Darwin
import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileMetadataTests {
    private func tempFile(_ name: String, _ contents: String = "x") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Set a raw extended attribute (the metadata xattrs are binary plists).
    @discardableResult
    private func setxattr(_ name: String, _ data: Data, on url: URL) -> Int32 {
        data.withUnsafeBytes { buffer in
            Darwin.setxattr(url.path, name, buffer.baseAddress, data.count, 0, 0)
        }
    }

    @Test func finderCommentRoundTrips() throws {
        let url = try tempFile("noted.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileMetadata.finderComment(of: url) == nil)  // none to start

        try FileMetadata.setFinderComment("Review before Friday", on: url)
        #expect(FileMetadata.finderComment(of: url) == "Review before Friday")

        try FileMetadata.setFinderComment("", on: url)  // empty clears it
        #expect(FileMetadata.finderComment(of: url) == nil)

        try FileMetadata.setFinderComment("", on: url)  // clearing an absent comment is not an error
    }

    @Test func finderTagsRoundTrip() throws {
        let url = try tempFile("tagged.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileMetadata.tags(of: url).isEmpty)  // none to start

        try FileMetadata.setTags(["Invoice", "2026"], on: url)
        #expect(FileMetadata.tags(of: url) == ["Invoice", "2026"])

        try FileMetadata.setTags(["Invoice"], on: url)  // narrowing replaces, not merges
        #expect(FileMetadata.tags(of: url) == ["Invoice"])

        try FileMetadata.setTags([], on: url)  // empty clears
        #expect(FileMetadata.tags(of: url).isEmpty)
        try FileMetadata.setTags([], on: url)  // clearing absent tags is not an error
    }

    @Test func whereFromsParsesTheBinaryPlistArray() throws {
        let url = try tempFile("download.zip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let urls = ["https://example.com/download.zip", "https://example.com/page.html"]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: urls, format: .binary, options: 0)
        #expect(setxattr("com.apple.metadata:kMDItemWhereFroms", plist, on: url) == 0)
        #expect(FileMetadata.whereFroms(of: url) == urls)
    }

    @Test func whereFromsIsEmptyWithoutTheAttribute() throws {
        let url = try tempFile("plain.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileMetadata.whereFroms(of: url).isEmpty)
    }

    @Test func finderCommentParsesTheStringPlist() throws {
        let url = try tempFile("noted.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: "Reviewed and approved", format: .binary, options: 0)
        #expect(setxattr("com.apple.metadata:kMDItemFinderComment", plist, on: url) == 0)
        #expect(FileMetadata.finderComment(of: url) == "Reviewed and approved")
        #expect(FileMetadata.finderComment(of: try tempFile("nocomment.txt")) == nil)
    }

    @Test func hidesExtensionRoundTrips() throws {
        let url = try tempFile("photo.jpg")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileMetadata.hidesExtension(url) == false)
        try FileMetadata.setHidesExtension(true, on: url)
        #expect(FileMetadata.hidesExtension(url) == true)
        try FileMetadata.setHidesExtension(false, on: url)
        #expect(FileMetadata.hidesExtension(url) == false)
    }

    @Test func appInfoReadsBundleVersionAndCopyright() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-app-\(UUID().uuidString)")
        let contents = dir.appendingPathComponent("Widget.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let info: [String: Any] = [
            "CFBundleShortVersionString": "2.5.1", "NSHumanReadableCopyright": "© 2026 Acme",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let result = FileMetadata.appInfo(of: dir.appendingPathComponent("Widget.app"))
        #expect(result?.version == "2.5.1")
        #expect(result?.copyright == "© 2026 Acme")
        // A non-.app returns nil.
        #expect(FileMetadata.appInfo(of: try tempFile("notanapp.txt")) == nil)
    }
}
