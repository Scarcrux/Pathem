import CoreGraphics
import Foundation
import ImageIO

/// Removes location (GPS) metadata from photos, losslessly and in place: it copies the image data
/// and drops only the GPS dictionary via `CGImageDestinationCopyImageSource`, so the pixels are never
/// re-encoded (no quality loss). The "share this without leaking where it was taken" privacy op. Pure
/// ImageIO, no AppKit, runs off-main.
public enum MetadataCleaner {
    public struct MetadataError: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// Whether the image at `url` carries GPS location metadata.
    public static func hasLocation(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }

    /// Strip GPS location from the image at `url`, in place and losslessly. A no-op (returns false)
    /// when the image has no location; returns true when it removed one. Writes to a temp file, then
    /// atomically replaces the original so a failure can't corrupt it.
    @discardableResult
    public static func removeLocation(from url: URL) throws -> Bool {
        guard hasLocation(url) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source)
        else { throw MetadataError(reason: "Couldn’t read the image.") }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".pathem-noloc-\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, CGImageSourceGetCount(source), nil)
        else { throw MetadataError(reason: "Couldn’t prepare the image.") }

        var cfError: Unmanaged<CFError>?
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &cfError) else {
            try? FileManager.default.removeItem(at: temp)
            throw cfError?.takeRetainedValue() ?? MetadataError(reason: "Couldn’t remove the location.")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return true
    }
}
