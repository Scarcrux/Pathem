import AppKit
import PathemEngine

/// A phase of a row drag, reported for the super-drag flick + its swipe trail. Screen points
/// (y-up), so BVC can convert them to the window overlay and MouseGesture can reduce them.
enum DragSessionEvent {
    case began(screen: NSPoint)
    case moved(screen: NSPoint)
    /// `flick` is the single cardinal direction when the drag ended past the threshold without
    /// a drop target accepting it (else nil: a real drop happened, or the movement was tiny).
    case ended(flick: String?)
}

/// The absolute path that keys a pane view's per-item state (cut dimming, tags, git). One
/// definition every view shares: a smart-result row carries its own folder in `location`,
/// otherwise the item lives in the view's folder. Built with `NSString` so it is cheap enough
/// to call per cell in the scroll hot path.
enum PaneItemKey {
    static func path(for entry: FileEntry, in directory: URL?) -> String {
        let base = entry.location ?? directory?.path
        guard let base else { return entry.name }
        return (base as NSString).appendingPathComponent(entry.name)
    }
}

/// The pluggable contents of a pane: the dense list table, or an icon/gallery
/// grid. PaneController drives whichever one conforms, so switching view modes is
/// just swapping the object behind this one API.
@MainActor
protocol PaneContentView: AnyObject {
    var scrollView: NSScrollView { get }
    /// The view PaneController embeds. Defaults to `scrollView`; composite views (gallery's
    /// preview + filmstrip) override it to embed their whole layout.
    var contentView: NSView { get }
    /// The focusable view (table or collection), for first-responder handoff.
    var keyView: NSView { get }
    var entries: [FileEntry] { get }
    var selectedEntries: [FileEntry] { get }
    /// Folder for drag (nil during search) and for resolving a row to a URL.
    var directoryURL: URL? { get set }
    var resolutionURL: URL? { get set }

    var onOpen: ((FileEntry) -> Void)? { get set }
    var onBecomeActive: (() -> Void)? { get set }
    var onSelectionChanged: (() -> Void)? { get set }
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)? { get set }
    /// `destination` is a specific subfolder to drop into (when the drag is over a folder
    /// row/item), or nil for the view's own folder.
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)? { get set }
    var onKeyChord: ((KeyChord) -> Bool)? { get set }
    var onMouseGesture: ((String) -> Bool)? { get set }
    /// Row-drag phases, for the super-drag flick + swipe trail. Only the list view drives it
    /// so far; other views default to no-op.
    var onDragSession: ((DragSessionEvent) -> Void)? { get set }
    /// Dragging items between folders moves by default (else copies).
    var dragMovesByDefault: Bool { get set }

    func setEntries(_ entries: [FileEntry], preserveState: Bool)
    func showPlaceholder(_ text: String?)
    func select(name: String)
    func selectNames(_ names: Set<String>)
    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool)
    /// Header sort-indicator state (list view only), for the layout smoke check.
    var debugSortIndicator: (column: String, ascending: Bool, drawn: Bool)? { get }
    /// The bounding rect of the current selection in window coordinates, clipped to the
    /// visible area (nil when nothing is selected or it is scrolled out of view). Lets the
    /// quick-actions bar float next to the selected items.
    func selectionRectInWindow() -> NSRect?
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool)
    /// Group the list under section headers by this key (list view only; others ignore it).
    func setGroupKey(_ key: ViewFormat.GroupKey)
    func invalidateTagCache()
    func setCalculateFolderSizes(_ on: Bool)
    func setSortFormat(_ format: ViewFormat)
    func setCutPaths(_ paths: Set<String>)
    func refreshDrilledColumns()
    func setGitStates(_ states: [String: GitFileState])
    /// Zoom the thumbnails (icon/gallery views); a no-op for list/column.
    func adjustZoom(_ delta: CGFloat)
    /// Open on a single click, and/or underline the item under the pointer.
    func setClickBehavior(singleClick: Bool, underlineHover: Bool)
    /// Paint the view's background with `color` (a folder background), `.clear` to let a picture
    /// behind it show through, or `nil` to restore the default system background.
    func setBackgroundColor(_ color: NSColor?)
}

extension PaneContentView {
    /// Most views embed their scroll view directly; the gallery overrides this.
    var contentView: NSView { scrollView }
    /// Only the list view groups rows under headers; the others ignore the key.
    func setGroupKey(_ key: ViewFormat.GroupKey) {}
    /// Grid views don't render tag dots yet, so dropping the cache is a no-op.
    func invalidateTagCache() {}
    /// Only the list view shows a size column, so others ignore this.
    func setCalculateFolderSizes(_ on: Bool) {}
    /// Only column view re-sorts its own drilled columns; list/icon/gallery are
    /// (re)sorted by the pane before setEntries.
    func setSortFormat(_ format: ViewFormat) {}
    /// Every view now dims cut items; this default is only a fallback.
    func setCutPaths(_ paths: Set<String>) {}
    /// Only column view has drilled columns to re-enumerate after a file op.
    func refreshDrilledColumns() {}
    /// Only icon/gallery views zoom.
    func adjustZoom(_ delta: CGFloat) {}
    /// Only the list view implements single-click / hover-underline for now.
    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {}
    /// Views that don't paint a custom background ignore the folder background.
    func setBackgroundColor(_ color: NSColor?) {}
    /// The list and column views draw git status letters; the icon/gallery grids don't yet.
    func setGitStates(_ states: [String: GitFileState]) {}
    /// Every pane view now shares one right-click menu (FileContextMenuController) and wires
    /// this up; the default stays as a fallback for any future view that doesn't.
    func setHiddenContextItems(_ ids: Set<String>) {}
    /// The user's right-click menu entry order (empty = default); paired with the hidden set.
    func setContextMenuOrder(_ order: [String]) {}
    /// User color rules (Directory-Opus labels) that tint/style filenames; empty = none.
    func setColorRules(_ rules: ColorRules) {}
    /// Size (decimal/binary) and date (relative/short/medium) display formats; list-only.
    func setFormats(size: Preferences.SizeFormat, date: Preferences.DateDisplay) {}
    /// Only the list view has a sortable header; other views report no indicator.
    var debugSortIndicator: (column: String, ascending: Bool, drawn: Bool)? { nil }
    /// List, icon, gallery, and column all report a selection rect now; this default is only a
    /// fallback (the bar then centers on the pane).
    func selectionRectInWindow() -> NSRect? { nil }
    /// Only the list view distinguishes drag copy vs move for now.
    var dragMovesByDefault: Bool {
        get { false }
        set {}
    }
    /// Only the list view drives super-drag flick/trail events for now.
    var onDragSession: ((DragSessionEvent) -> Void)? {
        get { nil }
        set {}
    }
}

extension FileListController: PaneContentView {
    var keyView: NSView { tableView }
    var onKeyChord: ((KeyChord) -> Bool)? {
        get { tableView.onKeyChord }
        set { tableView.onKeyChord = newValue }
    }
    var onMouseGesture: ((String) -> Bool)? {
        get { tableView.onMouseGesture }
        set { tableView.onMouseGesture = newValue }
    }
}
