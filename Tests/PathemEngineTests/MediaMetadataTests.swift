import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct MediaMetadataTests {
    /// Write a real PNG of the given size via ImageIO (no AppKit).
    private func writePNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-img-\(UUID().uuidString).png")
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func readsImageDimensions() throws {
        let url = try writePNG(width: 7, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = MediaMetadata.pixelSize(of: url)
        #expect(size?.width == 7)
        #expect(size?.height == 4)
        #expect(MediaMetadata.dimensionsLabel(of: url) == "7 × 4")
    }

    @Test func nonImageReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-notimg-\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MediaMetadata.pixelSize(of: url) == nil)
    }
}
