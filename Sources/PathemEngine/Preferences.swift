import Foundation

/// User preferences, persisted as config-as-data (prefs.json). Kept AppKit-free
/// (row height is a Double the app converts to CGFloat) so it stays in the
/// engine and unit-testable.
public struct Preferences: Codable, Sendable, Equatable {
    public enum Density: String, Codable, Sendable, CaseIterable { case compact, comfortable }

    /// Row spacing for the file list.
    public var density: Density
    /// Base font size for list rows.
    public var fontSize: Int
    /// Alternating row background colors.
    public var alternatingRows: Bool
    /// Include image OCR when building the semantic search index (slower, off by
    /// default; PDF and text contents are always indexed).
    public var searchOCR: Bool

    public init(
        density: Density = .comfortable, fontSize: Int = 13,
        alternatingRows: Bool = true, searchOCR: Bool = false
    ) {
        self.density = density
        self.fontSize = fontSize
        self.alternatingRows = alternatingRows
        self.searchOCR = searchOCR
    }

    public static let `default` = Preferences()

    /// Row height derived from density and font size.
    public var rowHeight: Double {
        Double(fontSize) + (density == .compact ? 6 : 11)
    }
}
