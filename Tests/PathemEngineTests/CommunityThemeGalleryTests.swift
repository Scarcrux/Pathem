import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PathemEngine

struct CommunityThemeGalleryTests {
    private let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/themes/gallery-fixture", isDirectory: true)

    @Test func denseScreenshotShrinksToFitPublishedBudget() throws {
        let width = 2400
        let height = 1600
        var generator: UInt32 = 12345
        let pixels = Data(
            (0..<(width * height)).map { _ in
                generator = generator &* 1_664_525 &+ 1_013_904_223
                return UInt8(generator >> 24)
            })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let source = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let jpeg = NSMutableData()
        let writer = try #require(
            CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(
            writer, source,
            [kCGImageDestinationLossyCompressionQuality: 0.40] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        try #require(jpeg.length <= 2 * 1024 * 1024)

        let bytes = try Data(contentsOf: fixture.appendingPathComponent("v1.submission.json"))
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        document["screenshots"] = [(jpeg as Data).base64EncodedString()]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let clean = try CommunityThemeGallery.submission(at: url)
        let image = try #require(clean.screenshots.first)
        #expect(image.count <= 300 * 1024)
        let cleanSource = try #require(CGImageSourceCreateWithData(image as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(cleanSource, 0, nil) as? [CFString: Any])
        let resizedWidth = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let resizedHeight = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(resizedWidth < width)
        #expect(abs(Double(resizedWidth) / Double(resizedHeight) - 1.5) < 0.01)
    }

    @Test func submissionStripsTrailingScreenshotPayload() throws {
        let bytes = try Data(contentsOf: fixture.appendingPathComponent("v1.submission.json"))
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let images = try #require(document["screenshots"] as? [String])
        let first = try #require(images.first)
        let image = try #require(Data(base64Encoded: first))
        let source = try #require(CGImageSourceCreateWithData(image as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let tagged = NSMutableData()
        let writer = try #require(
            CGImageDestinationCreateWithData(tagged, "public.jpeg" as CFString, 1, nil))
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
            kCGImagePropertyExifUserComment: "PATHEM-TEST-EXIF",
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 1.25,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.5,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        CGImageDestinationAddImage(
            writer, pixels,
            [
                kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyGPSDictionary: gps,
            ] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        let taggedImage = try #require(CGImageSourceCreateWithData(tagged as CFData, nil))
        let metadata = try #require(
            CGImageSourceCopyPropertiesAtIndex(taggedImage, 0, nil) as? [CFString: Any])
        let taggedExif = try #require(metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let taggedGPS = try #require(metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        try #require(
            taggedExif[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:01:02 03:04:05")
        try #require(taggedGPS[kCGImagePropertyGPSLatitude] as? Double == 1.25)
        try #require(taggedGPS[kCGImagePropertyGPSLongitude] as? Double == 2.5)

        let payload = Data("PATHEM-TEST-PRIVATE-SCREENSHOT-METADATA".utf8)
        document["screenshots"] = [((tagged as Data) + payload).base64EncodedString()]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let imported = try CommunityThemeGallery.submission(at: url)
        let exported = try JSONDecoder().decode(
            CommunityThemeRevision.self,
            from: CommunityThemeGallery.encodeSubmission(
                try JSONDecoder().decode(CommunityThemeRevision.self, from: Data(contentsOf: url))))
        for revision in [imported, exported] {
            let screenshot = try #require(revision.screenshots.first)
            #expect(screenshot.range(of: payload) == nil)
            #expect(screenshot.count <= 300 * 1024)
            let clean = try #require(CGImageSourceCreateWithData(screenshot as CFData, nil))
            let remaining = try #require(
                CGImageSourceCopyPropertiesAtIndex(clean, 0, nil) as? [CFString: Any])
            let remainingExif = remaining[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(remainingExif?[kCGImagePropertyExifDateTimeOriginal] == nil)
            #expect(remainingExif?[kCGImagePropertyExifUserComment] == nil)
            #expect(remaining[kCGImagePropertyGPSDictionary] == nil)
        }
    }

    @Test func creatorExportRoundTripsThroughReviewIntake() throws {
        let source = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v1.submission.json"))
        let exported = try CommunityThemeGallery.encodeSubmission(source)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try exported.write(to: url)
        let imported = try CommunityThemeGallery.submission(at: url)
        #expect(imported.reference == source.reference)
        #expect(imported.package == source.package)
        #expect(imported.screenshots.count == source.screenshots.count)
        var gallery = CommunityThemeGallery()
        try gallery.submit(imported)
        #expect(gallery.discover().isEmpty)

        let invalid = CommunityThemeRevision(
            id: source.id, version: source.version, title: source.title, summary: source.summary,
            creator: source.creator, license: source.license, source: source.source,
            tags: source.tags,
            package: source.package, screenshots: [Data("invalid image".utf8)])
        #expect(throws: CommunityThemeError.self) {
            try CommunityThemeGallery.encodeSubmission(invalid)
        }
    }

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
