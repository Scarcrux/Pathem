import Foundation

/// User preferences, persisted as config-as-data (prefs.json). Kept AppKit-free
/// (row height is a Double the app converts to CGFloat) so it stays in the
/// engine and unit-testable.
public struct Preferences: Codable, Sendable, Equatable {
    public var warnBeforeChangingExtension = true
    public var suggestFilenames = true
    /// Explicit opt-in. Cleanup uses date added to Trash, not the file's content age.
    public var trashAfter30Days = false
    public enum Density: String, Codable, Sendable, CaseIterable { case compact, comfortable }
    /// App appearance: follow the system, or force Light/Dark.
    public enum Appearance: String, Codable, Sendable, CaseIterable { case system, light, dark }
    /// Size of the navigation/toolbar button icons.
    public enum IconSize: String, Codable, Sendable, CaseIterable {
        case small, medium, large, extraLarge
        /// SF Symbol point size for the toolbar/navigation buttons.
        public var pointSize: Double {
            switch self {
            case .small: return 11
            case .medium: return 13  // the historical default look
            case .large: return 18  // the current default -- roughly Finder's toolbar
            case .extraLarge: return 24
            }
        }
    }

    /// How file sizes are shown: decimal (KB, MB; 1000-based, like Finder) or binary
    /// (KiB, MiB; 1024-based).
    public enum SizeFormat: String, Codable, Sendable, CaseIterable { case decimal, binary }
    /// How dates are shown: relative ("Yesterday at 3:14 PM"), short numeric, or medium.
    public enum DateDisplay: String, Codable, Sendable, CaseIterable {
        case relative, short, medium
    }

    /// Where a new tab or window opens: the current folder, Home, or a fixed folder.
    public enum NewTabLocation: String, Codable, Sendable, CaseIterable {
        case lastFolder, home, fixed
    }

    /// What the Recents smart location surfaces: files recently changed (default) or recently
    /// opened. Finder's Recents is "recently opened"; "modified" is often more useful in a file
    /// manager because it surfaces what actually changed. Either way the view sorts newest-first.
    public enum RecentsBasis: String, Codable, Sendable, CaseIterable { case modified, opened }

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
    /// Default base names for New Folder / New File (a number is appended if taken).
    public var newFolderName: String
    public var newFileName: String
    /// New tabs open at the end of the bar (true) or right after the current tab.
    public var newTabAtEnd: Bool
    /// Folder pairs for "follow paired folder" (Settings > Layout > Paired Folders).
    public var pairedFolders: [FolderPair] = []
    /// File-size units (decimal vs binary).
    public var sizeFormat: SizeFormat
    /// Date column format (relative / short / medium).
    public var dateDisplay: DateDisplay
    /// The view mode a folder opens in when it has no saved view of its own.
    public var defaultViewMode: ViewFormat.ViewMode
    /// The sort key/direction a folder uses when it has no saved view of its own.
    public var defaultSortKey: ViewFormat.SortKey
    public var defaultSortAscending: Bool
    /// What the Recents smart location shows: recently modified files (default) or recently opened.
    public var recentsBasis: RecentsBasis
    /// Keep folders on top when sorting a folder that has no saved view (Finder's "Keep folders on
    /// top"). Applies to unconfigured folders; a folder's own saved view keeps its setting.
    public var foldersFirst: Bool

    /// The view format for a folder with no saved view: the user's default view mode + sort,
    /// with the global show-hidden setting.
    public var defaultFormat: ViewFormat {
        ViewFormat(
            sortKey: defaultSortKey, ascending: defaultSortAscending,
            showHidden: showHiddenByDefault, foldersFirst: foldersFirst, viewMode: defaultViewMode)
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
    /// Leave caches, temporary folders and build output out of the automatic folder-size walk.
    public var skipCacheFolderSizes: Bool
    /// More folders to leave out: paths or folder names, separated by commas.
    public var folderSizeExclusions: String
    /// Save PDF and image markup without asking when the document is left, closed or the app
    /// quits. Off asks with Save, Cancel and Discard.
    public var autosaveMarkup: Bool
    /// Hide sidebar row labels (icons only) and narrow it, for a compact sidebar.
    public var compactSidebar: Bool
    /// Stack the two file panes top and bottom (left pane on top) instead of side by side.
    public var stackPanesVertically: Bool
    /// Show the folder tree column between the sidebar and the panes (hidden by default).
    public var showFolderTree: Bool
    /// The folder tree column's width in points.
    public var folderTreeWidth: Double
    /// Render sidebar place icons as monochrome templates that tint with the sidebar (a clean,
    /// Liquid-Glass look) instead of full-color brand glyphs (Google Drive, AirDrop, etc.).
    public var monochromeSidebarIcons: Bool
    /// Ask for confirmation before moving local items to the Trash (off by default,
    /// since the Trash is reversible).
    public var confirmBeforeDelete: Bool
    /// Optional ambient filing UI. Absent legacy settings remain off, never implicit opt-in.
    public var downloadSuggestionsEnabled: Bool
    /// What to do when a move/copy hits a name collision. `.ask` prompts (the default); the
    /// others resolve automatically so no dialog appears.
    public var conflictDefault: ConflictDefault
    /// Verify each copied file by SHA-256 after copying (slower: re-reads both files). Off by
    /// default. Applies to copies only; a move leaves no source to compare against.
    public var verifyCopies: Bool
    /// Dragging items between folders moves them by default (hold Command to copy).
    /// Off selects copy instead (hold Command to move).
    public var dragMovesByDefault: Bool
    /// Cap remote transfer speed in KB/s (0 = unlimited).
    public var bandwidthLimitKBps: Int
    /// Where magnet/torrent downloads are saved. Empty (or a folder that no longer exists) falls back
    /// to the system Downloads folder.
    public var torrentDownloadPath: String
    /// Ask before adding a magnet/torrent link that another app hands to Pathem. On by default:
    /// an inbound magnet doesn't just download, it seeds/reshares the content, so an unconsented
    /// one handed over by a webpage or another app is a real privacy/legal exposure. The confirm is
    /// cheap for the deliberate case (one click) and blocks the drive-by case.
    public var confirmInboundTorrents: Bool
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
    /// Pane-header buttons the user has hidden (ids: back, forward, up, viewSwitcher, sort,
    /// actions). Applies to every pane; the header row itself always stays so it can be
    /// customized back (right-click it, or the pane's Actions menu).
    public var hiddenPaneHeaderButtons: [String]
    /// Pane-header button order (same ids). Unknown ids are ignored and missing ones are appended
    /// in the built-in order, so an old or hand-edited value can never lose a button.
    public var paneHeaderButtonOrder: [String]
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
    /// Typing a plain character in a file list opens the find-as-you-type field (Find, Filter,
    /// Go, `>` commands, `?` semantic search). Off restores the table's built-in type-select.
    public var findAsYouType: Bool
    /// The swipe trail's color, as a "#RRGGBB" hex string.
    public var dragTrailColor: String
    /// The swipe trail's line width in points.
    public var dragTrailWidth: Double
    /// How long (seconds) a point stays on the swipe trail before it fades out. Longer = a
    /// longer, more visible trail.
    public var dragTrailDecay: Double

    /// The selected theme preset name (or "Custom" when the colors were edited by hand).
    public var themeName: String
    public var communityTheme: CommunityThemeRevision.Reference? = nil
    /// Accent color for Pathem-drawn chrome (list/sidebar selection, active pane/tab, breadcrumb),
    /// as "#RRGGBB". Empty means "use the system accent" (the default look).
    public var accentColorHex: String
    /// Optional window/pane background tint as "#RRGGBB". Empty means the system background.
    public var windowTintHex: String
    /// A saved file icon override. An empty string follows the theme.
    public var iconSetName: String
    public var folderStyleOverride: ThemeStyles.Folder? = nil
    public var toolbarStyleOverride: ThemeStyles.Toolbar? = nil
    public var themeStyles: ThemeStyles = .system
    public var themeArtwork: ThemeArtwork? = nil

    public var effectiveThemeStyles: ThemeStyles {
        ThemeStyles(
            folderStyleOverride ?? themeStyles.folder,
            ThemeStyles.FileIcons(rawValue: iconSetName) ?? themeStyles.fileIcons,
            toolbarStyleOverride ?? themeStyles.toolbar)
    }

    public init(
        density: Density = .comfortable, fontSize: Int = 13,
        alternatingRows: Bool = true, searchOCR: Bool = false,
        showFullPathInTitle: Bool = false, pathBarAtBottom: Bool = true,
        openConnectionsInNewTab: Bool = false, calculateFolderSizes: Bool = false,
        skipCacheFolderSizes: Bool = true, folderSizeExclusions: String = "",
        autosaveMarkup: Bool = false,
        compactSidebar: Bool = false, stackPanesVertically: Bool = false,
        showFolderTree: Bool = false, folderTreeWidth: Double = FolderTree.defaultWidth,
        monochromeSidebarIcons: Bool = false,
        confirmBeforeDelete: Bool = false, downloadSuggestionsEnabled: Bool = false,
        conflictDefault: ConflictDefault = .ask, verifyCopies: Bool = false,
        dragMovesByDefault: Bool = true, appearance: Appearance = .system,
        bandwidthLimitKBps: Int = 0, torrentDownloadPath: String = "",
        confirmInboundTorrents: Bool = true, showHiddenByDefault: Bool = false,
        useFinderGetInfo: Bool = false, previewInGalleryView: Bool = false,
        iconZoom: Double = 1, singleClickToOpen: Bool = false,
        underlineOnHover: Bool = false, instantTooltips: Bool = false,
        toolbarIconSize: IconSize = .large, hiddenContextItems: [String] = [],
        hiddenPaneHeaderButtons: [String] = [], paneHeaderButtonOrder: [String] = [],
        contextMenuOrder: [String] = [], colorRules: ColorRules = ColorRules(),
        sizeFormat: SizeFormat = .decimal, dateDisplay: DateDisplay = .relative,
        defaultViewMode: ViewFormat.ViewMode = .list, defaultSortKey: ViewFormat.SortKey = .name,
        defaultSortAscending: Bool = true, foldersFirst: Bool = true,
        recentsBasis: RecentsBasis = .modified,
        newTabLocation: NewTabLocation = .lastFolder, fixedStartFolder: String = "",
        middleClickOpensNewTab: Bool = true, commanderCommands: [String] = [],
        statusShowItemCount: Bool = true, statusShowSize: Bool = true,
        statusShowFreeSpace: Bool = false,
        newFolderName: String = "untitled folder", newFileName: String = "untitled file",
        newTabAtEnd: Bool = true,
        dragFlickActions: Bool = false, findAsYouType: Bool = true,
        dragTrailColor: String = "#3B82F6",
        dragTrailWidth: Double = 6, dragTrailDecay: Double = 0.6,
        themeName: String = "System", accentColorHex: String = "", windowTintHex: String = "",
        iconSetName: String = ""
    ) {
        self.themeName = themeName
        self.accentColorHex = accentColorHex
        self.windowTintHex = windowTintHex
        self.iconSetName = iconSetName
        self.dragFlickActions = dragFlickActions
        self.findAsYouType = findAsYouType
        self.dragTrailColor = dragTrailColor
        self.dragTrailWidth = dragTrailWidth
        self.dragTrailDecay = dragTrailDecay
        self.singleClickToOpen = singleClickToOpen
        self.underlineOnHover = underlineOnHover
        self.instantTooltips = instantTooltips
        self.toolbarIconSize = toolbarIconSize
        self.hiddenContextItems = hiddenContextItems
        self.hiddenPaneHeaderButtons = hiddenPaneHeaderButtons
        self.paneHeaderButtonOrder = paneHeaderButtonOrder
        self.contextMenuOrder = contextMenuOrder
        self.colorRules = colorRules
        self.sizeFormat = sizeFormat
        self.dateDisplay = dateDisplay
        self.defaultViewMode = defaultViewMode
        self.defaultSortKey = defaultSortKey
        self.defaultSortAscending = defaultSortAscending
        self.foldersFirst = foldersFirst
        self.recentsBasis = recentsBasis
        self.newTabLocation = newTabLocation
        self.fixedStartFolder = fixedStartFolder
        self.middleClickOpensNewTab = middleClickOpensNewTab
        self.commanderCommands = commanderCommands
        self.statusShowItemCount = statusShowItemCount
        self.statusShowSize = statusShowSize
        self.statusShowFreeSpace = statusShowFreeSpace
        self.newFolderName = newFolderName
        self.newFileName = newFileName
        self.newTabAtEnd = newTabAtEnd
        self.iconZoom = iconZoom
        self.showHiddenByDefault = showHiddenByDefault
        self.useFinderGetInfo = useFinderGetInfo
        self.previewInGalleryView = previewInGalleryView
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.torrentDownloadPath = torrentDownloadPath
        self.confirmInboundTorrents = confirmInboundTorrents
        self.appearance = appearance
        self.density = density
        self.fontSize = fontSize
        self.alternatingRows = alternatingRows
        self.searchOCR = searchOCR
        self.showFullPathInTitle = showFullPathInTitle
        self.pathBarAtBottom = pathBarAtBottom
        self.openConnectionsInNewTab = openConnectionsInNewTab
        self.calculateFolderSizes = calculateFolderSizes
        self.skipCacheFolderSizes = skipCacheFolderSizes
        self.folderSizeExclusions = folderSizeExclusions
        self.autosaveMarkup = autosaveMarkup
        self.compactSidebar = compactSidebar
        self.stackPanesVertically = stackPanesVertically
        self.showFolderTree = showFolderTree
        self.folderTreeWidth = folderTreeWidth
        self.monochromeSidebarIcons = monochromeSidebarIcons
        self.confirmBeforeDelete = confirmBeforeDelete
        self.downloadSuggestionsEnabled = downloadSuggestionsEnabled
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
        warnBeforeChangingExtension =
            try c.decodeIfPresent(Bool.self, forKey: .warnBeforeChangingExtension) ?? true
        suggestFilenames = try c.decodeIfPresent(Bool.self, forKey: .suggestFilenames) ?? true
        trashAfter30Days = try c.decodeIfPresent(Bool.self, forKey: .trashAfter30Days) ?? false
        // try? for the enum: an unknown raw value falls back rather than failing the file.
        density = (try? c.decode(Density.self, forKey: .density)) ?? d.density
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? d.fontSize
        alternatingRows =
            try c.decodeIfPresent(Bool.self, forKey: .alternatingRows) ?? d.alternatingRows
        searchOCR = try c.decodeIfPresent(Bool.self, forKey: .searchOCR) ?? d.searchOCR
        showFullPathInTitle =
            try c.decodeIfPresent(Bool.self, forKey: .showFullPathInTitle) ?? d.showFullPathInTitle
        pathBarAtBottom =
            try c.decodeIfPresent(Bool.self, forKey: .pathBarAtBottom) ?? d.pathBarAtBottom
        openConnectionsInNewTab =
            try c.decodeIfPresent(Bool.self, forKey: .openConnectionsInNewTab)
            ?? d.openConnectionsInNewTab
        calculateFolderSizes =
            try c.decodeIfPresent(Bool.self, forKey: .calculateFolderSizes)
            ?? d.calculateFolderSizes
        skipCacheFolderSizes =
            try c.decodeIfPresent(Bool.self, forKey: .skipCacheFolderSizes)
            ?? d.skipCacheFolderSizes
        folderSizeExclusions =
            try c.decodeIfPresent(String.self, forKey: .folderSizeExclusions)
            ?? d.folderSizeExclusions
        autosaveMarkup =
            try c.decodeIfPresent(Bool.self, forKey: .autosaveMarkup) ?? d.autosaveMarkup
        compactSidebar =
            try c.decodeIfPresent(Bool.self, forKey: .compactSidebar) ?? d.compactSidebar
        stackPanesVertically =
            try c.decodeIfPresent(Bool.self, forKey: .stackPanesVertically)
            ?? d.stackPanesVertically
        showFolderTree =
            try c.decodeIfPresent(Bool.self, forKey: .showFolderTree) ?? d.showFolderTree
        folderTreeWidth =
            FolderTree.clampedWidth(
                try c.decodeIfPresent(Double.self, forKey: .folderTreeWidth) ?? d.folderTreeWidth)
        monochromeSidebarIcons =
            try c.decodeIfPresent(Bool.self, forKey: .monochromeSidebarIcons)
            ?? d.monochromeSidebarIcons
        confirmBeforeDelete =
            try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDelete) ?? d.confirmBeforeDelete
        downloadSuggestionsEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .downloadSuggestionsEnabled) ?? false
        conflictDefault =
            (try? c.decode(ConflictDefault.self, forKey: .conflictDefault)) ?? d.conflictDefault
        verifyCopies = try c.decodeIfPresent(Bool.self, forKey: .verifyCopies) ?? d.verifyCopies
        dragMovesByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .dragMovesByDefault) ?? d.dragMovesByDefault
        appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? d.appearance
        bandwidthLimitKBps =
            try c.decodeIfPresent(Int.self, forKey: .bandwidthLimitKBps) ?? d.bandwidthLimitKBps
        torrentDownloadPath =
            try c.decodeIfPresent(String.self, forKey: .torrentDownloadPath)
            ?? d.torrentDownloadPath
        confirmInboundTorrents =
            try c.decodeIfPresent(Bool.self, forKey: .confirmInboundTorrents)
            ?? d.confirmInboundTorrents
        showHiddenByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .showHiddenByDefault) ?? d.showHiddenByDefault
        useFinderGetInfo =
            try c.decodeIfPresent(Bool.self, forKey: .useFinderGetInfo) ?? d.useFinderGetInfo
        previewInGalleryView =
            try c.decodeIfPresent(Bool.self, forKey: .previewInGalleryView)
            ?? d.previewInGalleryView
        iconZoom = try c.decodeIfPresent(Double.self, forKey: .iconZoom) ?? d.iconZoom
        singleClickToOpen =
            try c.decodeIfPresent(Bool.self, forKey: .singleClickToOpen) ?? d.singleClickToOpen
        underlineOnHover =
            try c.decodeIfPresent(Bool.self, forKey: .underlineOnHover) ?? d.underlineOnHover
        instantTooltips =
            try c.decodeIfPresent(Bool.self, forKey: .instantTooltips) ?? d.instantTooltips
        toolbarIconSize =
            (try? c.decode(IconSize.self, forKey: .toolbarIconSize)) ?? d.toolbarIconSize
        hiddenContextItems =
            try c.decodeIfPresent([String].self, forKey: .hiddenContextItems)
            ?? d.hiddenContextItems
        hiddenPaneHeaderButtons =
            try c.decodeIfPresent([String].self, forKey: .hiddenPaneHeaderButtons)
            ?? d.hiddenPaneHeaderButtons
        paneHeaderButtonOrder =
            try c.decodeIfPresent([String].self, forKey: .paneHeaderButtonOrder)
            ?? d.paneHeaderButtonOrder
        contextMenuOrder =
            try c.decodeIfPresent([String].self, forKey: .contextMenuOrder) ?? d.contextMenuOrder
        colorRules = try c.decodeIfPresent(ColorRules.self, forKey: .colorRules) ?? d.colorRules
        sizeFormat = (try? c.decode(SizeFormat.self, forKey: .sizeFormat)) ?? d.sizeFormat
        dateDisplay = (try? c.decode(DateDisplay.self, forKey: .dateDisplay)) ?? d.dateDisplay
        defaultViewMode =
            (try? c.decode(ViewFormat.ViewMode.self, forKey: .defaultViewMode)) ?? d.defaultViewMode
        defaultSortKey =
            (try? c.decode(ViewFormat.SortKey.self, forKey: .defaultSortKey)) ?? d.defaultSortKey
        defaultSortAscending =
            try c.decodeIfPresent(Bool.self, forKey: .defaultSortAscending)
            ?? d.defaultSortAscending
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? d.foldersFirst
        recentsBasis =
            try c.decodeIfPresent(RecentsBasis.self, forKey: .recentsBasis) ?? d.recentsBasis
        newTabLocation =
            (try? c.decode(NewTabLocation.self, forKey: .newTabLocation)) ?? d.newTabLocation
        fixedStartFolder =
            try c.decodeIfPresent(String.self, forKey: .fixedStartFolder) ?? d.fixedStartFolder
        middleClickOpensNewTab =
            try c.decodeIfPresent(Bool.self, forKey: .middleClickOpensNewTab)
            ?? d.middleClickOpensNewTab
        commanderCommands =
            try c.decodeIfPresent([String].self, forKey: .commanderCommands) ?? d.commanderCommands
        statusShowItemCount =
            try c.decodeIfPresent(Bool.self, forKey: .statusShowItemCount) ?? d.statusShowItemCount
        statusShowSize =
            try c.decodeIfPresent(Bool.self, forKey: .statusShowSize) ?? d.statusShowSize
        statusShowFreeSpace =
            try c.decodeIfPresent(Bool.self, forKey: .statusShowFreeSpace) ?? d.statusShowFreeSpace
        newFolderName =
            try c.decodeIfPresent(String.self, forKey: .newFolderName) ?? d.newFolderName
        newFileName = try c.decodeIfPresent(String.self, forKey: .newFileName) ?? d.newFileName
        newTabAtEnd = try c.decodeIfPresent(Bool.self, forKey: .newTabAtEnd) ?? d.newTabAtEnd
        pairedFolders =
            try c.decodeIfPresent([FolderPair].self, forKey: .pairedFolders) ?? d.pairedFolders
        dragFlickActions =
            try c.decodeIfPresent(Bool.self, forKey: .dragFlickActions) ?? d.dragFlickActions
        findAsYouType = try c.decodeIfPresent(Bool.self, forKey: .findAsYouType) ?? d.findAsYouType
        dragTrailColor =
            try c.decodeIfPresent(String.self, forKey: .dragTrailColor) ?? d.dragTrailColor
        dragTrailWidth =
            try c.decodeIfPresent(Double.self, forKey: .dragTrailWidth) ?? d.dragTrailWidth
        dragTrailDecay =
            try c.decodeIfPresent(Double.self, forKey: .dragTrailDecay) ?? d.dragTrailDecay
        themeName = try c.decodeIfPresent(String.self, forKey: .themeName) ?? d.themeName
        communityTheme = try c.decodeIfPresent(
            CommunityThemeRevision.Reference.self, forKey: .communityTheme)
        accentColorHex =
            try c.decodeIfPresent(String.self, forKey: .accentColorHex) ?? d.accentColorHex
        windowTintHex =
            try c.decodeIfPresent(String.self, forKey: .windowTintHex) ?? d.windowTintHex
        iconSetName = try c.decodeIfPresent(String.self, forKey: .iconSetName) ?? d.iconSetName
        // Releases before bundled styles persisted System even without a user override.
        // Current documents always encode themeStyles, including an explicit System override.
        if iconSetName == "System", !c.contains(.themeStyles) { iconSetName = "" }
        folderStyleOverride = try c.decodeIfPresent(
            ThemeStyles.Folder.self, forKey: .folderStyleOverride)
        toolbarStyleOverride = try c.decodeIfPresent(
            ThemeStyles.Toolbar.self, forKey: .toolbarStyleOverride)
        themeArtwork = try? c.decodeIfPresent(ThemeArtwork.self, forKey: .themeArtwork)
        themeStyles = try c.decodeIfPresent(ThemeStyles.self, forKey: .themeStyles) ?? .system
        // A retired built-in keeps its stored colors and styles and becomes an unnamed custom theme.
        if ThemePreset.isRetiredBuiltIn(
            name: themeName, accentHex: accentColorHex, backgroundHex: windowTintHex,
            isCommunityTheme: communityTheme != nil)
        {
            themeName = ""
        }
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
