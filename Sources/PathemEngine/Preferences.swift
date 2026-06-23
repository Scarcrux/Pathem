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
    /// Show the active folder's full POSIX path in the window title (off = folder
    /// name, like Finder).
    public var showFullPathInTitle: Bool
    /// Place the breadcrumb path bar at the bottom of the pane (Finder-style)
    /// instead of the top.
    public var pathBarAtBottom: Bool
    /// Opening a saved connection uses a new tab instead of the active one.
    public var openConnectionsInNewTab: Bool

    public init(
        density: Density = .comfortable, fontSize: Int = 13,
        alternatingRows: Bool = true, searchOCR: Bool = false,
        showFullPathInTitle: Bool = false, pathBarAtBottom: Bool = false,
        openConnectionsInNewTab: Bool = false
    ) {
        self.density = density
        self.fontSize = fontSize
        self.alternatingRows = alternatingRows
        self.searchOCR = searchOCR
        self.showFullPathInTitle = showFullPathInTitle
        self.pathBarAtBottom = pathBarAtBottom
        self.openConnectionsInNewTab = openConnectionsInNewTab
    }

    public static let `default` = Preferences()

    /// Row height derived from density and font size.
    public var rowHeight: Double {
        Double(fontSize) + (density == .compact ? 6 : 11)
    }

    // Tolerant decoding: a prefs.json written by an older build won't have the
    // newer keys, so each decodes with its default rather than failing the whole
    // file (which would reset the user's settings).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.default
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? d.density
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? d.fontSize
        alternatingRows = try c.decodeIfPresent(Bool.self, forKey: .alternatingRows) ?? d.alternatingRows
        searchOCR = try c.decodeIfPresent(Bool.self, forKey: .searchOCR) ?? d.searchOCR
        showFullPathInTitle =
            try c.decodeIfPresent(Bool.self, forKey: .showFullPathInTitle) ?? d.showFullPathInTitle
        pathBarAtBottom = try c.decodeIfPresent(Bool.self, forKey: .pathBarAtBottom) ?? d.pathBarAtBottom
        openConnectionsInNewTab =
            try c.decodeIfPresent(Bool.self, forKey: .openConnectionsInNewTab) ?? d.openConnectionsInNewTab
    }
}
