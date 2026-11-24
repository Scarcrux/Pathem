import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PathemEngine

struct CommunityThemeGalleryTests {
    private let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/themes/gallery-fixture", isDirectory: true)

    @Test func rejectionAndWithdrawalNeverExposeRevisionForInstall() throws {
        let v1 = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v1.submission.json"))
        let v2 = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v2.submission.json"))
        var gallery = CommunityThemeGallery()
        try gallery.submit(v1)
        #expect(throws: CommunityThemeError.self) { try gallery.submit(v2) }
        #expect(throws: CommunityThemeError.self) { try gallery.install(v1.reference) }
        try gallery.review(
            v1.reference, outcome: .rejected, reviewer: "Reviewer", note: "Rejected in test.")
        #expect(gallery.discover().isEmpty)
        #expect(throws: CommunityThemeError.self) {
            try gallery.review(
                v1.reference, outcome: .approved, reviewer: "Reviewer", note: "Duplicate decision.")
        }
        try gallery.submit(v2)
        try gallery.review(
            v2.reference, outcome: .approved, reviewer: "Reviewer", note: "Approved in test.")
        #expect(gallery.discover("marsh nature") == [v2])
        #expect(throws: CommunityThemeError.self) { try gallery.install(v1.reference) }
        try gallery.withdraw(v2.id)
        #expect(throws: CommunityThemeError.self) { try gallery.install(v2.reference) }
        #expect(gallery.discover().isEmpty)
    }

    @Test func invalidMetadataPackageAndScreenshotsAreRejected() throws {
        let data = try Data(contentsOf: fixture.appendingPathComponent("v1.submission.json"))
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try #require(
            CGContext(
                data: nil, width: 2401, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        var gallery = CommunityThemeGallery()
        for (field, value) in [
            ("id", "../tidal-marsh"), ("version", 0), ("creator", "\n"),
            ("license", ""), ("source", "a\rhidden line"),
            ("package", Data("{}".utf8).base64EncodedString()),
            ("screenshots", [Data("GIF89a".utf8).base64EncodedString()]),
            ("screenshots", [Data(repeating: 0, count: 2 * 1024 * 1024 + 1).base64EncodedString()]),
            ("screenshots", [png.base64EncodedString()]),
        ] as [(String, Any)] {
            var invalid = original
            invalid[field] = value
            let revision = try JSONDecoder().decode(
                CommunityThemeRevision.self, from: JSONSerialization.data(withJSONObject: invalid))
            #expect(throws: (any Error).self) { try gallery.submit(revision) }
            #expect(gallery.entries.isEmpty)
        }
    }

    @Test func failedTransactionLeavesStoredRevisionPending() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("gallery.json")
        let v1 = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v1.submission.json"))
        _ = try CommunityThemeGallery.update(at: store) { try $0.submit(v1) }
        #expect(throws: CommunityThemeError.self) {
            try CommunityThemeGallery.update(at: store) {
                try $0.review(
                    v1.reference, outcome: .approved, reviewer: "Reviewer",
                    note: "Approved in test.")
                try $0.submit(v1)
            }
        }
        let reloaded = try CommunityThemeGallery.load(from: store)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.review == nil)
        #expect(reloaded.discover().isEmpty)
    }
}
