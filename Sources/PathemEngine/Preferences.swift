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
    /// Compute and show folder sizes in the list (Finder's "Calculate all sizes").
    public var calculateFolderSizes: Bool
    /// Hide sidebar row labels (icons only) and narrow it, for a compact sidebar.
    public var compactSidebar: Bool
    /// Ask for confirmation before moving local items to the Trash (off by default,
    /// since the Trash is reversible).
    public var confirmBeforeDelete: Bool
    /// Dragging items between folders moves them by default (hold Command to copy).
    /// Off keeps the Finder-like default of copy (hold Command to move).
    public var dragMovesByDefault: Bool

    public init(
        density: Density = .comfortable, fontSize: Int = 13,
        alternatingRows: Bool = true, searchOCR: Bool = false,
        showFullPathInTitle: Bool = false, pathBarAtBottom: Bool = true,
        openConnectionsInNewTab: Bool = false, calculateFolderSizes: Bool = false,
        compactSidebar: Bool = false, confirmBeforeDelete: Bool = false,
        dragMovesByDefault: Bool = false
    ) {
        self.density = density
        self.fontSize = fontSize
        self.alternatingRows = alternatingRows
        self.searchOCR = searchOCR
        self.showFullPathInTitle = showFullPathInTitle
        self.pathBarAtBottom = pathBarAtBottom
        self.openConnectionsInNewTab = openConnectionsInNewTab
        self.calculateFolderSizes = calculateFolderSizes
        self.compactSidebar = compactSidebar
        self.confirmBeforeDelete = confirmBeforeDelete
        self.dragMovesByDefault = dragMovesByDefault
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
        // try? for the enum: an unknown raw value falls back rather than failing the file.
        density = (try? c.decode(Density.self, forKey: .density)) ?? d.density
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? d.fontSize
        alternatingRows = try c.decodeIfPresent(Bool.self, forKey: .alternatingRows) ?? d.alternatingRows
        searchOCR = try c.decodeIfPresent(Bool.self, forKey: .searchOCR) ?? d.searchOCR
        showFullPathInTitle =
            try c.decodeIfPresent(Bool.self, forKey: .showFullPathInTitle) ?? d.showFullPathInTitle
        pathBarAtBottom = try c.decodeIfPresent(Bool.self, forKey: .pathBarAtBottom) ?? d.pathBarAtBottom
        openConnectionsInNewTab =
            try c.decodeIfPresent(Bool.self, forKey: .openConnectionsInNewTab) ?? d.openConnectionsInNewTab
        calculateFolderSizes =
            try c.decodeIfPresent(Bool.self, forKey: .calculateFolderSizes) ?? d.calculateFolderSizes
        compactSidebar = try c.decodeIfPresent(Bool.self, forKey: .compactSidebar) ?? d.compactSidebar
        confirmBeforeDelete =
            try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDelete) ?? d.confirmBeforeDelete
        dragMovesByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .dragMovesByDefault) ?? d.dragMovesByDefault
    }
}
