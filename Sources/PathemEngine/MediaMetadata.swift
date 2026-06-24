import Foundation
import ImageIO

/// Lightweight media metadata via ImageIO (header-only reads, no full decode), kept
/// AppKit-free so it lives in the engine. The basis for image dimensions in Get Info
/// (and, later, EXIF columns and rename tokens).
public enum MediaMetadata {
    /// Pixel dimensions of an image file, or nil if it isn't a readable image.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// A "W × H" dimensions string for an image, or nil.
    public static func dimensionsLabel(of url: URL) -> String? {
        guard let size = pixelSize(of: url) else { return nil }
        return "\(size.width) × \(size.height)"
    }
}
