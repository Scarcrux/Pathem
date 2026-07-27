import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Crops an image file to a pixel rectangle and writes a copy, preserving the source format when it
/// can (PNG fallback). Pure Core Graphics / ImageIO -- no AppKit -- so it's testable and the crop UI
/// just has to compute the rectangle.
public enum ImageCropper {
    public struct CropError: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// The suggested output name for a crop of `name`: base + " Cropped" + the original extension.
    public static func croppedName(for name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        return ext.isEmpty ? "\(base) Cropped" : "\(base) Cropped.\(ext)"
    }

    /// The pixel dimensions of the image at `url`, or nil if it can't be read. Handy for the crop UI.
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Crop the image at `source` to `pixelRect` (image pixel coordinates, origin top-left) and write
    /// it to `destination`. Throws if the image can't be read or the rectangle doesn't overlap it.
    public static func crop(_ source: URL, pixelRect: CGRect, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw CropError(reason: "Couldn’t read the image.") }

        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let rect = pixelRect.integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cropped = cgImage.cropping(to: rect) else {
            throw CropError(reason: "The crop area is outside the image.")
        }

        let type =
            (CGImageSourceGetType(imageSource) as String?).flatMap { UTType($0) }
            ?? .png
        guard let imageDestination = CGImageDestinationCreateWithURL(
            destination as CFURL, type.identifier as CFString, 1, nil)
        else { throw CropError(reason: "Couldn’t write the cropped image.") }
        CGImageDestinationAddImage(imageDestination, cropped, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw CropError(reason: "Couldn’t write the cropped image.")
        }
    }
}
