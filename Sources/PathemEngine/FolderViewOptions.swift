import Foundation

/// Optional folder overrides. Nil follows the global preference, preserving old saved views.
public struct FolderViewOptions: Codable, Sendable, Equatable {
    public enum LabelPosition: String, Codable, Sendable, CaseIterable { case below, right }
    public var fontSize: Int?
    public var dateDisplay: Preferences.DateDisplay?
    public var iconScale: Double?
    public var listIconSize: Int?
    public var showIconPreviews: Bool?
    public var gridSpacing: Int?
    public var labelPosition: LabelPosition?
    public var columns: [String]?
    public var columnWidths: [String: Double]?
    public var calculateFolderSizes: Bool?
    public var showLibraryFolder: Bool?

    public init() {}

    /// Sanitize config-as-data at its delivery boundary, including nonfinite widths/scales.
    public var normalized: Self {
        var result = self
        result.fontSize = fontSize.map { min(24, max(9, $0)) }
        result.iconScale = iconScale.map { $0.isFinite ? min(3, max(0.5, $0)) : 1 }
        result.listIconSize = listIconSize.map { min(64, max(16, $0)) }
        result.gridSpacing = gridSpacing.map { min(64, max(0, $0)) }
        if let columns {
            var seen = Set<String>()
            var valid = columns.filter { Self.columnIDs.contains($0) && seen.insert($0).inserted }
            if !valid.contains("name") { valid.insert("name", at: 0) }
            result.columns = valid
        }
        result.columnWidths = columnWidths?.filter { Self.columnIDs.contains($0.key) }
            .mapValues { $0.isFinite ? min(2000, max(40, $0)) : 150 }
        return result
    }

    public static let columnIDs = [
        "name", "size", "kind", "date", "dateCreated", "dateAccessed", "dateAdded", "tags",
        "cloudStatus", "sharedBy", "modifiedBy", "version", "ext", "git", "path",
        "dimensions", "permissions", "owner", "whereFrom", "comment",
    ]

    public static func defaults(_ prefs: Preferences) -> Self {
        var result = Self()
        result.fontSize = prefs.fontSize
        result.dateDisplay = prefs.dateDisplay
        result.iconScale = prefs.iconZoom
        result.listIconSize = 16
        result.showIconPreviews = true
        result.gridSpacing = 8
        result.labelPosition = .below
        result.calculateFolderSizes = prefs.calculateFolderSizes
        result.showLibraryFolder = false
        return result
    }

    public func inheriting(_ fallback: Self) -> Self {
        var result = self
        result.fontSize = fontSize ?? fallback.fontSize
        result.dateDisplay = dateDisplay ?? fallback.dateDisplay
        result.iconScale = iconScale ?? fallback.iconScale
        result.listIconSize = listIconSize ?? fallback.listIconSize
        result.showIconPreviews = showIconPreviews ?? fallback.showIconPreviews
        result.gridSpacing = gridSpacing ?? fallback.gridSpacing
        result.labelPosition = labelPosition ?? fallback.labelPosition
        result.columns = columns ?? fallback.columns
        result.columnWidths = columnWidths ?? fallback.columnWidths
        result.calculateFolderSizes = calculateFolderSizes ?? fallback.calculateFolderSizes
        result.showLibraryFolder = showLibraryFolder ?? fallback.showLibraryFolder
        return result.normalized
    }
}
