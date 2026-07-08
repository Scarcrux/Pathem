import Foundation

/// A per-folder background: a solid color and/or a picture, shown behind the file list when that
/// folder is open (the classic Mac OS "View Options > Background" feature). Colors are hex strings
/// and the picture is a file path, so the model stays Foundation-only; the app maps them to
/// NSColor/NSImage. An image takes precedence over a color when both are set.
public struct FolderBackground: Codable, Sendable, Equatable {
    public var colorHex: String  // "#RRGGBB", or "" for none
    public var imagePath: String  // absolute path to a picture, or "" for none

    public init(colorHex: String = "", imagePath: String = "") {
        self.colorHex = colorHex
        self.imagePath = imagePath
    }

    public var isEmpty: Bool { colorHex.isEmpty && imagePath.isEmpty }
}

/// Folder backgrounds keyed by absolute folder path, persisted as folder-backgrounds.json.
public struct FolderBackgrounds: Codable, Sendable, Equatable {
    public var byPath: [String: FolderBackground]

    public init(byPath: [String: FolderBackground] = [:]) { self.byPath = byPath }

    public static let `default` = FolderBackgrounds()

    /// Tolerant decode so an older/newer file never resets the user's backgrounds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byPath = (try? c.decodeIfPresent([String: FolderBackground].self, forKey: .byPath)) ?? [:]
    }

    public func background(for path: String) -> FolderBackground? {
        guard let bg = byPath[path], !bg.isEmpty else { return nil }
        return bg
    }

    public mutating func set(_ background: FolderBackground?, for path: String) {
        if let background, !background.isEmpty {
            byPath[path] = background
        } else {
            byPath[path] = nil
        }
    }
}
