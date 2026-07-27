import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct MetadataCleanerTests {
    @Test func removesGPSInPlaceAndKeepsThePixels() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("geo.jpg")
        try writeJPEGWithGPS(width: 32, height: 24, to: url)

        #expect(MetadataCleaner.hasLocation(url))
        let removed = try MetadataCleaner.removeLocation(from: url)
        #expect(removed)
        #expect(!MetadataCleaner.hasLocation(url))
        // The image is still valid and unchanged in size (lossless copy, not a re-encode to nothing).
        #expect(ImageCropper.pixelSize(of: url) == CGSize(width: 32, height: 24))
    }

    @Test func noLocationIsANoOp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.jpg")
        try writeJPEGWithGPS(width: 16, height: 16, to: url, includeGPS: false)
        #expect(!MetadataCleaner.hasLocation(url))
        #expect(try MetadataCleaner.removeLocation(from: url) == false)
    }

    private func writeJPEGWithGPS(width: Int, height: Int, to url: URL, includeGPS: Bool = true) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        var props: [CFString: Any] = [:]
        if includeGPS {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0090, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any]
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
    }
}
