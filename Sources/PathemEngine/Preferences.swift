import Foundation

/// User preferences, persisted as config-as-data (prefs.json). Kept AppKit-free
/// (row height is a Double the app converts to CGFloat) so it stays in the
/// engine and unit-testable.
public struct Preferences: Codable, Sendable, Equatable {
    public enum Density: String, Codable, Sendable, CaseIterable { case compact, comfortable }
    /// App appearance: follow the system, or force Light/Dark.
    public enum Appearance: String, Codable, Sendable, CaseIterable { case system, light, dark }
    /// Size of the navigation/toolbar button icons.
    public enum IconSize: String, Codable, Sendable, CaseIterable {
        case small, medium, large
        /// SF Symbol point size for the toolbar/navigation buttons.
        public var pointSize: Double {
            switch self {
            case .small: return 11
            case .medium: return 13  // the historical default look
            case .large: return 18
            }
        }
    }

    /// How file sizes are shown: decimal (KB, MB; 1000-based, like Finder) or binary
    /// (KiB, MiB; 1024-based).
    public enum SizeFormat: String, Codable, Sendable, CaseIterable { case decimal, binary }
    /// How dates are shown: relative ("Yesterday at 3:14 PM"), short numeric, or medium.
    public enum DateDisplay: String, Codable, Sendable, CaseIterable { case relative, short, medium }

    /// Where a new tab or window opens: the current folder, Home, or a fixed folder.
    public enum NewTabLocation: String, Codable, Sendable, CaseIterable { case lastFolder, home, fixed }

    /// Row spacing for the file list.
    public var density: Density
    /// Where new tabs/windows open.
    public var newTabLocation: NewTabLocation
    /// The folder new tabs/windows open to when `newTabLocation` is `.fixed`.
    public var fixedStartFolder: String
    /// Middle-clicking a folder opens it in a new tab.
    public var middleClickOpensNewTab: Bool
    /// The command ids bound to the Commander bar's F3–F8 buttons (six entries). Empty = the
    /// orthodox defaults (View / Edit / Copy / Move / MkDir / Delete).
    public var commanderCommands: [String]
    /// What the pane's bottom status bar shows.
    public var statusShowItemCount: Bool
    public var statusShowSize: Bool
    public var statusShowFreeSpace: Bool
    /// File-size units (decimal vs binary).
    public var sizeFormat: SizeFormat
    /// Date column format (relative / short / medium).
    public var dateDisplay: DateDisplay
    /// The view mode a folder opens in when it has no saved view of its own.
    public var defaultViewMode: ViewFormat.ViewMode
    /// The sort key/direction a folder uses when it has no saved view of its own.
    public var defaultSortKey: ViewFormat.SortKey
    public var defaultSortAscending: Bool

    /// The view format for a folder with no saved view: the user's default view mode + sort,
    /// with the global show-hidden setting.
    public var defaultFormat: ViewFormat {
        ViewFormat(
            sortKey: defaultSortKey, ascending: defaultSortAscending,
            showHidden: showHiddenByDefault, foldersFirst: true, viewMode: defaultViewMode)
    }
    /// App appearance (System/Light/Dark).
    public var appearance: Appearance
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
    /// What to do when a move/copy hits a name collision. `.ask` prompts (the default); the
    /// others resolve automatically so no dialog appears.
    public var conflictDefault: ConflictDefault
    /// Verify each copied file by SHA-256 after copying (slower: re-reads both files). Off by
    /// default. Applies to copies only; a move leaves no source to compare against.
    public var verifyCopies: Bool
    /// Dragging items between folders moves them by default (hold Command to copy).
    /// Off keeps the Finder-like default of copy (hold Command to move).
    public var dragMovesByDefault: Bool
    /// Cap remote transfer speed in KB/s (0 = unlimited).
    public var bandwidthLimitKBps: Int
    /// Show dotfiles/hidden files in every folder by default.
    public var showHiddenByDefault: Bool
    /// Use Finder's Get Info window instead of Pathem's inspector.
    public var useFinderGetInfo: Bool
    /// In gallery/column views, automatically show the preview pane and follow the selection.
    public var previewInGalleryView: Bool
    /// Icon/gallery thumbnail zoom multiplier (0.5–3.0).
    public var iconZoom: Double
    /// Open items with a single click (instead of double).
    public var singleClickToOpen: Bool
    /// Underline the item name under the pointer while hovering.
    public var underlineOnHover: Bool
    /// Show tooltips immediately instead of after the system hover delay.
    public var instantTooltips: Bool
    /// Size of the navigation/toolbar button icons.
    public var toolbarIconSize: IconSize
    /// Command ids hidden from the file list's right-click menu (config-as-data
    /// customization). Empty = the full default menu.
    public var hiddenContextItems: [String]
    /// The order of the file right-click menu's entries (command ids and the "@openWith" /
    /// "@tags" submenu tokens). Empty = the default order. Separators are auto-inserted
    /// between groups, so they aren't stored here.
    public var contextMenuOrder: [String]
    /// User rules that color and style filenames by extension, name, size, or kind
    /// (Directory-Opus-style labels). Empty = no coloring.
    public var colorRules: ColorRules
    /// "Super-drag": flick the selection a short way and release (off a drop target) to fire
    /// a directional quick action, with a swipe trail for feedback. Off by default.
    public var dragFlickActions: Bool
    /// The swipe trail's color, as a "#RRGGBB" hex string.
    public var dragTrailColor: String
    /// The swipe trail's line width in points.
    public var dragTrailWidth: Double
    /// How long (seconds) a point stays on the swipe trail before it fades out. Longer = a
    /// longer, more visible trail.
    public var dragTrailDecay: Double

    /// The selected theme preset name (or "Custom" when the colors were edited by hand).
    public var themeName: String
    /// Accent color for Pathem-drawn chrome (list/sidebar selection, active pane/tab, breadcrumb),
    /// as "#RRGGBB". Empty means "use the system accent" (the default look).
    public var accentColorHex: String
    /// Optional window/pane background tint as "#RRGGBB". Empty means the system background.
    public var windowTintHex: String
    /// The active icon set name ("System" uses the OS icons; the others theme file icons).
    public var iconSetName: String

    public init(
        density: Density = .comfortable, fontSize: Int = 13,
        alternatingRows: Bool = true, searchOCR: Bool = false,
        showFullPathInTitle: Bool = false, pathBarAtBottom: Bool = true,
        openConnectionsInNewTab: Bool = false, calculateFolderSizes: Bool = false,
        compactSidebar: Bool = false, confirmBeforeDelete: Bool = false,
        conflictDefault: ConflictDefault = .ask, verifyCopies: Bool = false,
        dragMovesByDefault: Bool = false, appearance: Appearance = .system,
        bandwidthLimitKBps: Int = 0, showHiddenByDefault: Bool = false,
        useFinderGetInfo: Bool = false, previewInGalleryView: Bool = false,
        iconZoom: Double = 1, singleClickToOpen: Bool = false,
        underlineOnHover: Bool = false, instantTooltips: Bool = false,
        toolbarIconSize: IconSize = .medium, hiddenContextItems: [String] = [],
        contextMenuOrder: [String] = [], colorRules: ColorRules = ColorRules(),
        sizeFormat: SizeFormat = .decimal, dateDisplay: DateDisplay = .medium,
        defaultViewMode: ViewFormat.ViewMode = .list, defaultSortKey: ViewFormat.SortKey = .name,
        defaultSortAscending: Bool = true,
        newTabLocation: NewTabLocation = .lastFolder, fixedStartFolder: String = "",
        middleClickOpensNewTab: Bool = true, commanderCommands: [String] = [],
        statusShowItemCount: Bool = true, statusShowSize: Bool = true, statusShowFreeSpace: Bool = false,
        dragFlickActions: Bool = false, dragTrailColor: String = "#3B82F6",
        dragTrailWidth: Double = 6, dragTrailDecay: Double = 0.6,
        themeName: String = "System", accentColorHex: String = "", windowTintHex: String = "",
        iconSetName: String = "System"
    ) {
        self.themeName = themeName
        self.accentColorHex = accentColorHex
        self.windowTintHex = windowTintHex
        self.iconSetName = iconSetName
        self.dragFlickActions = dragFlickActions
        self.dragTrailColor = dragTrailColor
        self.dragTrailWidth = dragTrailWidth
        self.dragTrailDecay = dragTrailDecay
        self.singleClickToOpen = singleClickToOpen
        self.underlineOnHover = underlineOnHover
        self.instantTooltips = instantTooltips
        self.toolbarIconSize = toolbarIconSize
        self.hiddenContextItems = hiddenContextItems
        self.contextMenuOrder = contextMenuOrder
        self.colorRules = colorRules
        self.sizeFormat = sizeFormat
        self.dateDisplay = dateDisplay
        self.defaultViewMode = defaultViewMode
        self.defaultSortKey = defaultSortKey
        self.defaultSortAscending = defaultSortAscending
        self.newTabLocation = newTabLocation
        self.fixedStartFolder = fixedStartFolder
        self.middleClickOpensNewTab = middleClickOpensNewTab
        self.commanderCommands = commanderCommands
        self.statusShowItemCount = statusShowItemCount
        self.statusShowSize = statusShowSize
        self.statusShowFreeSpace = statusShowFreeSpace
        self.iconZoom = iconZoom
        self.showHiddenByDefault = showHiddenByDefault
        self.useFinderGetInfo = useFinderGetInfo
        self.previewInGalleryView = previewInGalleryView
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.appearance = appearance
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
        self.conflictDefault = conflictDefault
        self.verifyCopies = verifyCopies
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
        conflictDefault = (try? c.decode(ConflictDefault.self, forKey: .conflictDefault)) ?? d.conflictDefault
        verifyCopies = try c.decodeIfPresent(Bool.self, forKey: .verifyCopies) ?? d.verifyCopies
        dragMovesByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .dragMovesByDefault) ?? d.dragMovesByDefault
        appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? d.appearance
        bandwidthLimitKBps =
            try c.decodeIfPresent(Int.self, forKey: .bandwidthLimitKBps) ?? d.bandwidthLimitKBps
        showHiddenByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .showHiddenByDefault) ?? d.showHiddenByDefault
        useFinderGetInfo =
            try c.decodeIfPresent(Bool.self, forKey: .useFinderGetInfo) ?? d.useFinderGetInfo
        previewInGalleryView =
            try c.decodeIfPresent(Bool.self, forKey: .previewInGalleryView) ?? d.previewInGalleryView
        iconZoom = try c.decodeIfPresent(Double.self, forKey: .iconZoom) ?? d.iconZoom
        singleClickToOpen =
            try c.decodeIfPresent(Bool.self, forKey: .singleClickToOpen) ?? d.singleClickToOpen
        underlineOnHover =
            try c.decodeIfPresent(Bool.self, forKey: .underlineOnHover) ?? d.underlineOnHover
        instantTooltips =
            try c.decodeIfPresent(Bool.self, forKey: .instantTooltips) ?? d.instantTooltips
        toolbarIconSize = (try? c.decode(IconSize.self, forKey: .toolbarIconSize)) ?? d.toolbarIconSize
        hiddenContextItems =
            try c.decodeIfPresent([String].self, forKey: .hiddenContextItems) ?? d.hiddenContextItems
        contextMenuOrder =
            try c.decodeIfPresent([String].self, forKey: .contextMenuOrder) ?? d.contextMenuOrder
        colorRules = try c.decodeIfPresent(ColorRules.self, forKey: .colorRules) ?? d.colorRules
        sizeFormat = (try? c.decode(SizeFormat.self, forKey: .sizeFormat)) ?? d.sizeFormat
        dateDisplay = (try? c.decode(DateDisplay.self, forKey: .dateDisplay)) ?? d.dateDisplay
        defaultViewMode = (try? c.decode(ViewFormat.ViewMode.self, forKey: .defaultViewMode)) ?? d.defaultViewMode
        defaultSortKey = (try? c.decode(ViewFormat.SortKey.self, forKey: .defaultSortKey)) ?? d.defaultSortKey
        defaultSortAscending = try c.decodeIfPresent(Bool.self, forKey: .defaultSortAscending) ?? d.defaultSortAscending
        newTabLocation = (try? c.decode(NewTabLocation.self, forKey: .newTabLocation)) ?? d.newTabLocation
        fixedStartFolder = try c.decodeIfPresent(String.self, forKey: .fixedStartFolder) ?? d.fixedStartFolder
        middleClickOpensNewTab =
            try c.decodeIfPresent(Bool.self, forKey: .middleClickOpensNewTab) ?? d.middleClickOpensNewTab
        commanderCommands =
            try c.decodeIfPresent([String].self, forKey: .commanderCommands) ?? d.commanderCommands
        statusShowItemCount =
            try c.decodeIfPresent(Bool.self, forKey: .statusShowItemCount) ?? d.statusShowItemCount
        statusShowSize = try c.decodeIfPresent(Bool.self, forKey: .statusShowSize) ?? d.statusShowSize
        statusShowFreeSpace =
            try c.decodeIfPresent(Bool.self, forKey: .statusShowFreeSpace) ?? d.statusShowFreeSpace
        dragFlickActions =
            try c.decodeIfPresent(Bool.self, forKey: .dragFlickActions) ?? d.dragFlickActions
        dragTrailColor =
            try c.decodeIfPresent(String.self, forKey: .dragTrailColor) ?? d.dragTrailColor
        dragTrailWidth =
            try c.decodeIfPresent(Double.self, forKey: .dragTrailWidth) ?? d.dragTrailWidth
        dragTrailDecay =
            try c.decodeIfPresent(Double.self, forKey: .dragTrailDecay) ?? d.dragTrailDecay
        themeName = try c.decodeIfPresent(String.self, forKey: .themeName) ?? d.themeName
        accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex) ?? d.accentColorHex
        windowTintHex = try c.decodeIfPresent(String.self, forKey: .windowTintHex) ?? d.windowTintHex
        iconSetName = try c.decodeIfPresent(String.self, forKey: .iconSetName) ?? d.iconSetName
    }
}

/// The default response to a name collision on move/copy. `.ask` prompts; the others resolve
/// automatically so no confirmation appears.
public enum ConflictDefault: String, Codable, Sendable, CaseIterable {
    case ask, replace, keepBoth, skip

    /// The resolution to apply without asking, or nil for `.ask` (prompt the user).
    public var resolution: FileOperations.ConflictResolution? {
        switch self {
        case .ask: return nil
        case .replace: return .replace
        case .keepBoth: return .keepBoth
        case .skip: return .skip
        }
    }
}
