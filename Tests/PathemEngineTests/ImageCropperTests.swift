import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct ImageCropperTests {
    @Test func croppedNameAppendsCropped() {
        #expect(ImageCropper.croppedName(for: "photo.jpg") == "photo Cropped.jpg")
        #expect(ImageCropper.croppedName(for: "noext") == "noext Cropped")
    }

    @Test func cropsToTheRequestedPixelRect() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.png")
        try writeSolidPNG(width: 100, height: 100, to: src)
        #expect(ImageCropper.pixelSize(of: src) == CGSize(width: 100, height: 100))

        let out = dir.appendingPathComponent("out.png")
        try ImageCropper.crop(src, pixelRect: CGRect(x: 25, y: 25, width: 50, height: 40), to: out)
        #expect(ImageCropper.pixelSize(of: out) == CGSize(width: 50, height: 40))
    }

    @Test func rectOutsideImageThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.png")
        try writeSolidPNG(width: 100, height: 100, to: src)
        let out = dir.appendingPathComponent("out.png")
        #expect(throws: ImageCropper.CropError.self) {
            try ImageCropper.crop(src, pixelRect: CGRect(x: 500, y: 500, width: 50, height: 50), to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    private func writeSolidPNG(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
    }
}
