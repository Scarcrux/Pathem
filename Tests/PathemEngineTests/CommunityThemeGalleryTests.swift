import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PathemEngine

struct CommunityThemeGalleryTests {
    private let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/themes/gallery-fixture", isDirectory: true)

    /// The first preferred format this Mac can encode. Nil only where no such encoder exists,
    /// in which case the sanitizer falls back to PNG or JPEG.
    private var expectedScreenshotType: String? {
        CommunityThemeRevision.preferredScreenshotTypes.first {
            CGImageDestinationCreateWithData(NSMutableData(), $0 as CFString, 1, nil) != nil
        }
    }

    private func imageType(_ data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }
            as String?
    }

    /// The major brand of an ISO BMFF file, read from its leading `ftyp` box.
    private func fileTypeBrand(_ data: Data) -> String? {
        guard data.count >= 12, data[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        return String(decoding: data[8..<12], as: UTF8.self)
    }

    private func screenshot(as type: String, quality: Double? = nil) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for band in 0..<8 {
            context.setFillColor(
                red: Double(band) / 8, green: 0.4, blue: 1 - Double(band) / 8, alpha: 1)
            context.fill(CGRect(x: band * 80, y: 0, width: 80, height: 400))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let writer = try #require(
            CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(
            writer, image,
            quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        try #require(CGImageDestinationFinalize(writer))
        return output as Data
    }

    private func listing(
        _ id: String, _ title: String, creator: String = "Pathem contributors",
        _ appearance: Preferences.Appearance, tags: [String]
    ) throws -> CommunityThemeRevision {
        CommunityThemeRevision(
            id: id, version: 1, title: title, summary: "A theme.", creator: creator,
            license: "MIT", source: nil, tags: tags,
            package: try ThemePackage.encode(
                ThemePreset(
                    name: title, appearance: appearance, accentHex: "#336699",
                    backgroundHex: appearance == .system ? "" : "#101820")),
            screenshots: [])
    }

    @Test func appearanceFilterReadsThePackageAndCombinesWithSearch() throws {
        let themes = [
            try listing("delft", "Delft", .light, tags: ["light", "blue"]),
            try listing("kiln", "Kiln", creator: "Ada", .light, tags: ["warm"]),
            try listing("smithy", "Smithy", .dark, tags: ["dark", "warm"]),
            // The control: the tag and the title both say light, the package says dark.
            try listing("lightless", "Lightless", .dark, tags: ["light"]),
            try listing("graphite", "Graphite", .system, tags: ["neutral"]),
        ]
        func ids(_ query: String, _ filter: CommunityThemeGallery.AppearanceFilter) -> [String] {
            CommunityThemeGallery.matching(themes, query: query, appearance: filter).map(\.id)
        }
        #expect(themes.map(\.appearance) == [.light, .light, .dark, .dark, .system])
        #expect(ids("", .all) == ["delft", "kiln", "smithy", "lightless", "graphite"])
        #expect(ids("", .light) == ["delft", "kiln"])
        #expect(ids("", .dark) == ["smithy", "lightless"])
        // Search still reads tags, and each filter narrows the same search differently.
        #expect(ids("light", .all) == ["delft", "lightless"])
        #expect(ids("light", .light) == ["delft"])
        #expect(ids("light", .dark) == ["lightless"])
        #expect(ids("warm", .light) == ["kiln"])
        #expect(ids("warm", .dark) == ["smithy"])
        #expect(ids("ada WARM", .light) == ["kiln"])
        #expect(ids("ada", .dark).isEmpty)
        #expect(ids("neutral", .light).isEmpty && ids("neutral", .dark).isEmpty)
    }

    @Test func appearanceFilterAppliesToBrowseAndInstalled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-gallery-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("gallery.json")
        let light = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v1.submission.json"))
        #expect(light.appearance == .light)
        var dark = try ThemePackage.decode(light.package)
        dark.appearance = .dark
        let night = CommunityThemeRevision(
            id: "tidal-night", version: 1, title: "Tidal Night", summary: light.summary,
            creator: light.creator, license: light.license, source: light.source,
            tags: ["light"], package: try ThemePackage.encode(dark),
            screenshots: light.screenshots)
        let gallery = try CommunityThemeGallery.update(at: store) { gallery in
            for revision in [light, night] {
                try gallery.submit(revision)
                try gallery.review(
                    revision.reference, outcome: .approved, reviewer: "Reviewer", note: "Fine")
                try gallery.install(revision.reference)
            }
        }
        #expect(gallery.discover().map(\.id) == ["tidal-marsh", "tidal-night"])
        #expect(gallery.discover(appearance: .light).map(\.id) == ["tidal-marsh"])
        #expect(gallery.discover(appearance: .dark).map(\.id) == ["tidal-night"])
        #expect(gallery.discover("tidal", appearance: .dark).map(\.id) == ["tidal-night"])
        #expect(gallery.discover("marsh", appearance: .dark).isEmpty)
        #expect(gallery.installedThemes().map(\.id) == ["tidal-marsh", "tidal-night"])
        #expect(gallery.installedThemes(appearance: .light).map(\.id) == ["tidal-marsh"])
        #expect(gallery.installedThemes("night", appearance: .dark).map(\.id) == ["tidal-night"])
        #expect(gallery.installedThemes("night", appearance: .light).isEmpty)
    }

    @Test func sanitizedScreenshotUsesThePreferredFormatAndRoundTripsThroughTheCatalog() throws {
        let expected = try #require(expectedScreenshotType)
        let v1 = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v1.submission.json"))
        for image in v1.screenshots {
            #expect(imageType(image) == expected)
            #expect(["heic", "heix"].contains(try #require(fileTypeBrand(image))))
            #expect(image.count <= 300 * 1024)
        }
        var gallery = CommunityThemeGallery()
        try gallery.submit(v1)
        try gallery.review(
            v1.reference, outcome: .approved, reviewer: "Reviewer", note: "Approved in test.")
        let published = try SharedThemeCatalog.decode(
            SharedThemeCatalog(reviewed: gallery).encoded())
        #expect(published.themes == [v1])
        #expect(published.themes.first?.screenshots.compactMap(imageType) == [expected, expected])
    }

    /// Listings published before the format change hold PNG or JPEG. They sit beside HEIC
    /// listings in one catalog, and all of them must decode.
    @Test func catalogMixingScreenshotFormatsDecodes() throws {
        let v1 = try JSONDecoder().decode(
            CommunityThemeRevision.self,
            from: Data(contentsOf: fixture.appendingPathComponent("v1.submission.json")))
        #expect(v1.screenshots.compactMap(imageType) == ["public.jpeg", "public.jpeg"])
        var formats: [(String, Double?)] = [("public.png", nil), ("public.jpeg", 0.82)]
        for type in CommunityThemeRevision.preferredScreenshotTypes
        where CGImageDestinationCreateWithData(NSMutableData(), type as CFString, 1, nil) != nil {
            formats.append((type, CommunityThemeRevision.preferredScreenshotQuality))
        }
        // A catalog that only ever held the old formats would not test the new ones.
        try #require(formats.count > 2)
        var gallery = CommunityThemeGallery()
        try gallery.submit(v1)
        try gallery.review(
            v1.reference, outcome: .approved, reviewer: "Reviewer", note: "Approved in test.")
        for (index, (type, quality)) in formats.enumerated() {
            let image = try screenshot(as: type, quality: quality)
            #expect(imageType(image) == type)
            let listing = CommunityThemeRevision(
                id: "mixed-\(index)", version: 1, title: "Mixed \(index)", summary: v1.summary,
                creator: v1.creator, license: v1.license, source: v1.source, tags: v1.tags,
                package: v1.package, screenshots: [image])
            try gallery.submit(listing)
            try gallery.review(
                listing.reference, outcome: .approved, reviewer: "Reviewer",
                note: "Approved in test.")
        }
        let published = try SharedThemeCatalog.decode(
            SharedThemeCatalog(reviewed: gallery).encoded())
        #expect(published.themes.count == formats.count + 1)
        let types = Set(published.themes.flatMap { $0.screenshots.compactMap(imageType) })
        #expect(types == Set(formats.map(\.0)))
    }

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
        #expect(imageType(image) == expectedScreenshotType)
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
            #expect(imageType(screenshot) == expectedScreenshotType)
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
        // AVIF is not a published format: macOS 15 cannot write it, so no listing may hold it.
        if CGImageDestinationCreateWithData(NSMutableData(), "public.avif" as CFString, 1, nil)
            != nil
        {
            var invalid = original
            invalid["screenshots"] = [try screenshot(as: "public.avif").base64EncodedString()]
            let revision = try JSONDecoder().decode(
                CommunityThemeRevision.self, from: JSONSerialization.data(withJSONObject: invalid))
            #expect(throws: CommunityThemeError.self) { try gallery.submit(revision) }
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

    /// Release builds never read the gallery store at launch: the applied theme is a snapshot in
    /// Preferences. Losing the store entry must leave that snapshot readable and resettable.
    @Test func appliedThemeSurvivesAMissingOrCorruptStoreEntry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("shared-community-themes.json")
        let saved = folder.appendingPathComponent("preferences.json")
        let v1 = try CommunityThemeGallery.submission(
            at: fixture.appendingPathComponent("v1.submission.json"))
        let installed = try CommunityThemeGallery.update(at: store) {
            try $0.submit(v1)
            try $0.review(
                v1.reference, outcome: .approved, reviewer: "Reviewer", note: "Approved in test.")
            try $0.install(v1.reference)
        }
        let intact = try Data(contentsOf: store)

        // Apply the installed theme the way Settings does, then persist it.
        let theme = try #require(installed.installed[v1.id]).theme()
        var applied = Preferences()
        theme.apply(to: &applied)
        applied.communityTheme = v1.reference
        try JSONEncoder().encode(applied).write(to: saved)
        #expect(ThemePreset(preferences: applied) != ThemePreset(preferences: Preferences()))

        // What every later launch sees, whatever happened to the store in between.
        func relaunch() throws -> Preferences {
            try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: saved))
        }
        func expectSnapshotIntactAndResettable() throws {
            var loaded = try relaunch()
            #expect(loaded.communityTheme == v1.reference)
            #expect(ThemePreset(preferences: loaded) == ThemePreset(preferences: applied))
            ThemePreset.system.apply(to: &loaded)
            #expect(loaded.communityTheme == nil)
            #expect(ThemePreset(preferences: loaded) == .system)
        }

        // 1. The entry was uninstalled but the appearance reset was never saved.
        let removed = try CommunityThemeGallery.update(at: store) { try $0.uninstall(v1.id) }
        #expect(removed.installed[v1.id] == nil)
        try expectSnapshotIntactAndResettable()
        // The dangling reference does not block installing and applying the theme again.
        let again = try CommunityThemeGallery.update(at: store) { try $0.install(v1.reference) }
        #expect(try again.installed[v1.id]?.theme() == theme)

        // 2. The store file is gone: it reads as an empty gallery, not an error.
        try FileManager.default.removeItem(at: store)
        #expect(try CommunityThemeGallery.load(from: store).installed.isEmpty)
        try expectSnapshotIntactAndResettable()

        // 3. The store is damaged: truncated, garbage, or an installed entry with no listing.
        var orphaned = try #require(
            JSONSerialization.jsonObject(with: intact) as? [String: Any])
        orphaned["entries"] = []
        for damaged in [
            intact.prefix(intact.count / 2), Data("not json".utf8), Data(),
            try JSONSerialization.data(withJSONObject: orphaned),
        ] {
            try damaged.write(to: store)
            // Loading reports an error instead of crashing or returning a partial gallery.
            #expect(throws: (any Error).self) { try CommunityThemeGallery.load(from: store) }
            try expectSnapshotIntactAndResettable()
            // Known limit: a damaged store is never rewritten, so the gallery stays closed.
            #expect(throws: (any Error).self) {
                try CommunityThemeGallery.update(at: store) { _ in }
            }
            #expect(try Data(contentsOf: store) == damaged)
        }
    }
}
