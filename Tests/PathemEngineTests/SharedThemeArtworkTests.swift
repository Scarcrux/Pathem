import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PathemEngine

struct SharedThemeArtworkTests {
    @Test func versionThreeRoundTripsArtworkAndOlderPalettesPreserveIt() throws {
        let png = try image(width: 32)
        let artwork = try ThemeArtwork(
            files: ["folder": png, "document": png],
            toolbar: ["magnifyingglass": png])
        var theme = ThemePreset.harbor
        theme.artwork = artwork
        let decoded = try ThemePackage.decode(ThemePackage.encode(theme))
        #expect(decoded == theme)

        var prefs = Preferences()
        decoded.apply(to: &prefs)
        #expect(prefs.themeArtwork == artwork)
        ThemePreset(name: "Palette", appearance: .dark, accentHex: "").apply(to: &prefs)
        #expect(prefs.themeArtwork == artwork)
        ThemePreset.system.apply(to: &prefs)
        #expect(prefs.themeArtwork == nil)
    }

    @Test func rejectsOversizedOrInvalidArtwork() throws {
        let png = try image(width: 257)
        #expect(throws: ThemePackage.ValidationError.invalidArtwork) {
            try ThemeArtwork(files: ["folder": png], toolbar: [:])
        }
        #expect(throws: ThemePackage.ValidationError.invalidArtwork) {
            try ThemeArtwork(files: ["folder": Data("<svg/>".utf8)], toolbar: [:])
        }
        #expect(throws: ThemePackage.ValidationError.invalidArtwork) {
            try ThemeArtwork(files: [:], toolbar: ["../file": image(width: 32)])
        }
    }

    private func image(width: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: 16,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return png as Data
    }
}
