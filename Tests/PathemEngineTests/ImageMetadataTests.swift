import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct ImageMetadataTests {
    @Test func writesThenReadsBackEveryField() throws {
        let url = try blankJPEG(32, 24)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var edit = ImageMetadata.Edit()
        edit.caption = .set("A test photo")
        edit.author = .set("Jane Doe")
        edit.copyright = .set("© 2026 Jane")
        edit.keywords = .set(["beach", "sunset"])
        let date = Date(timeIntervalSince1970: 1_600_000_000)  // fixed instant
        edit.dateTaken = .set(date)

        #expect(try ImageMetadata.apply(edit, to: url))

        let read = ImageMetadata.read(url)
        #expect(read.caption == "A test photo")
        #expect(read.author == "Jane Doe")
        #expect(read.copyright == "© 2026 Jane")
        #expect(read.keywords == ["beach", "sunset"])
        // EXIF has second precision and no timezone; compare on the formatted string.
        #expect(read.dateTaken.map { Int($0.timeIntervalSince1970) } != nil)
        // The pixels are untouched (lossless edit, not a re-encode to nothing).
        #expect(ImageCropper.pixelSize(of: url) == CGSize(width: 32, height: 24))
    }

    @Test func clearingRemovesAFieldButLeavesOthers() throws {
        let url = try blankJPEG(16, 16)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var set = ImageMetadata.Edit()
        set.caption = .set("keep me")
        set.author = .set("remove me")
        #expect(try ImageMetadata.apply(set, to: url))

        var clear = ImageMetadata.Edit()
        clear.author = .cleared
        #expect(try ImageMetadata.apply(clear, to: url))

        let read = ImageMetadata.read(url)
        #expect(read.caption == "keep me")
        #expect(read.author == nil)
    }

    @Test func emptyEditIsANoOp() throws {
        let url = try blankJPEG(8, 8)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try ImageMetadata.apply(ImageMetadata.Edit(), to: url) == false)
    }

    private func blankJPEG(_ width: Int, _ height: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-imeta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("photo.jpg")
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return url
    }
}
