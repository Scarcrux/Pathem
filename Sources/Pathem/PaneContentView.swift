import AppKit
import PathemEngine

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
}

extension PaneContentView {
    /// Most views embed their scroll view directly; the gallery overrides this.
    var contentView: NSView { scrollView }
    /// Grid views don't render tag dots yet, so dropping the cache is a no-op.
    func invalidateTagCache() {}
    /// Only the list view shows a size column, so others ignore this.
    func setCalculateFolderSizes(_ on: Bool) {}
    /// Only column view re-sorts its own drilled columns; list/icon/gallery are
    /// (re)sorted by the pane before setEntries.
    func setSortFormat(_ format: ViewFormat) {}
    /// Only the list view dims cut items for now.
    func setCutPaths(_ paths: Set<String>) {}
    /// Only column view has drilled columns to re-enumerate after a file op.
    func refreshDrilledColumns() {}
    /// Only icon/gallery views zoom.
    func adjustZoom(_ delta: CGFloat) {}
    /// Only the list view implements single-click / hover-underline for now.
    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {}
    /// Only the list view draws git overlays for now.
    func setGitStates(_ states: [String: GitFileState]) {}
    /// Only the list view has a sortable header; other views report no indicator.
    var debugSortIndicator: (column: String, ascending: Bool, drawn: Bool)? { nil }
    /// Views without a row-rect concept fall back to no anchor (the bar centers on the pane).
    func selectionRectInWindow() -> NSRect? { nil }
    /// Only the list view distinguishes drag copy vs move for now.
    var dragMovesByDefault: Bool {
        get { false }
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
