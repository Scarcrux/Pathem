import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct FileColumnsTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-cols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func computesPermissionsAndOwner() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: file.path)

        let info = FileColumns.gather(file, [.permissions, .owner])
        #expect(info.permissions == "rw-r-----")
        #expect(info.owner != nil)
        #expect(info.dimensions == nil)  // not requested
    }

    @Test func computesImageDimensions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png")
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        let info = FileColumns.gather(png, [.dimensions])
        #expect(info.dimensions?.contains("120") == true)
        #expect(info.dimensions?.contains("80") == true)
    }

    @Test func readsDownloadSource() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dl.pdf")
        try Data("x".utf8).write(to: file)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["https://files.example.com/dl.pdf"], format: .binary, options: 0)
        _ = plist.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0)
        }
        let info = FileColumns.gather(file, [.whereFrom])
        #expect(info.whereFrom == "files.example.com")
    }
}
