import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct ImageConverterTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write a solid-color PNG of the given pixel size using ImageIO (no AppKit).
    private func writePNG(_ url: URL, size: Int) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func pixelWidth(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int
        else { return nil }
        return width
    }

    @Test func convertsFormat() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("photo.png")
        try writePNG(png, size: 100)

        let result = await ImageConverter.process([png], options: .init(format: .jpeg))
        #expect(result.failures.isEmpty)
        #expect(result.outputs.count == 1)
        let out = try #require(result.outputs.first)
        #expect(out.lastPathComponent == "photo.jpg")
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func resizesToMaxDimension() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("big.png")
        try writePNG(png, size: 200)

        let result = await ImageConverter.process([png], options: .init(maxDimension: 50))
        #expect(result.failures.isEmpty)
        let out = try #require(result.outputs.first)
        #expect(out.lastPathComponent == "big resized.png")  // resize keeps format, renames
        #expect(pixelWidth(out) == 50)
        #expect(pixelWidth(png) == 200)  // original untouched
    }

    private func writeJPEGWithGPS(_ url: URL, size: Int) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.77, kCGImagePropertyGPSLongitude: 122.41]
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func hasGPS(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }

    @Test func stripsMetadata() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("geo.jpg")
        try writeJPEGWithGPS(jpg, size: 40)
        #expect(hasGPS(jpg))  // sanity: it starts with GPS

        let result = await ImageConverter.process([jpg], options: .init(stripMetadata: true))
        let out = try #require(result.outputs.first)
        #expect(out.lastPathComponent == "geo clean.jpg")
        #expect(!hasGPS(out))  // stripped
        #expect(hasGPS(jpg))  // original untouched
    }

    @Test func noOpProducesNothing() async {
        let result = await ImageConverter.process(
            [URL(fileURLWithPath: "/tmp/whatever.png")], options: .init())
        #expect(result.outputs.isEmpty)
        #expect(result.failures.isEmpty)
    }
}
