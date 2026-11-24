import Foundation
import ImageIO

/// Embedded, bounded PNG art. Keys select existing icon roles and never refer to files.
public struct ThemeArtwork: Codable, Equatable, Sendable {
    public let files: [String: Data]
    public let toolbar: [String: Data]

    private static let roles: Set<String> = [
        "folder", "image", "video", "audio", "archive", "code", "pdf", "document", "app", "generic",
    ]

    public init(files: [String: Data], toolbar: [String: Data]) throws {
        guard files.count + toolbar.count <= 16,
            Set(files.keys).isSubset(of: Self.roles),
            toolbar.keys.allSatisfy({ key in
                (1...96).contains(key.utf8.count)
                    && key.utf8.allSatisfy {
                        (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45
                    }
            }),
            (Array(files.values) + Array(toolbar.values)).allSatisfy(Self.validPNG)
        else { throw ThemePackage.ValidationError.invalidArtwork }
        self.files = files
        self.toolbar = toolbar
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            files: values.decode([String: Data].self, forKey: .files),
            toolbar: values.decode([String: Data].self, forKey: .toolbar))
    }

    private enum CodingKeys: String, CodingKey { case files, toolbar }

    private static func validPNG(_ data: Data) -> Bool {
        guard data.count <= 16 * 1024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) as String? == "public.png",
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...256).contains(width), (1...256).contains(height)
        else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
            && CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
    }
}
