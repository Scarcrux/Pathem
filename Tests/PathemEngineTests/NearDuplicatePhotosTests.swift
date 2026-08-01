import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct NearDuplicatePhotosTests {
    @Test func identicalImagesClusterWithAValidKeeper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-neardup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two byte-identical photo-like images are guaranteed near-duplicates (feature-print
        // distance 0), so the clustering and keeper choice are exercised deterministically without
        // depending on how Vision scores subtly-different synthetic images.
        let a = dir.appendingPathComponent("a.png")
        try writePhotoLikePNG(to: a)
        let b = dir.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: a, to: b)

        let groups = NearDuplicatePhotos.groups(of: [a, b])
        #expect(groups.count == 1)
        #expect(Set(groups[0].urls.map(\.lastPathComponent)) == ["a.png", "b.png"])
        // The keeper is a real index into the cluster, so the cull can never delete every copy.
        #expect(groups[0].urls.indices.contains(groups[0].keepIndex))
        #expect(groups[0].extras.count == 1)  // one kept, one queued for removal
    }

    /// A small gradient-with-texture PNG, so Vision has real structure to feature-print (a flat
    /// color wouldn't produce a meaningful print).
    private func writePhotoLikePNG(to url: URL, side: Int = 96) throws {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<side {
            for x in 0..<side {
                context.setFillColor(
                    CGColor(
                        red: CGFloat(x) / CGFloat(side), green: CGFloat(y) / CGFloat(side),
                        blue: CGFloat((x ^ y) % 64) / 64.0, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "NearDuplicatePhotosTests", code: 1)
        }
    }

    @Test func emptyAndNonImagesYieldNoGroups() throws {
        #expect(NearDuplicatePhotos.groups(of: []).isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-neardup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        // No feature prints for non-images, so no clusters (and no crash).
        #expect(NearDuplicatePhotos.groups(of: [a, b]).isEmpty)
    }

    @Test func groupExtrasExcludeTheKeeper() {
        let urls = [URL(fileURLWithPath: "/x/1.jpg"), URL(fileURLWithPath: "/x/2.jpg"), URL(fileURLWithPath: "/x/3.jpg")]
        let group = NearDuplicatePhotos.Group(urls: urls, keepIndex: 1)
        #expect(group.extras == [urls[0], urls[2]])
    }
}
