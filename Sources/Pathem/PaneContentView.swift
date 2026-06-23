import AppKit
import PathemEngine

/// The pluggable contents of a pane: the dense list table, or an icon/gallery
/// grid. PaneController drives whichever one conforms, so switching view modes is
/// just swapping the object behind this one API.
@MainActor
protocol PaneContentView: AnyObject {
    var scrollView: NSScrollView { get }
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
    var onDropFiles: ((_ urls: [URL], _ move: Bool) -> Void)? { get set }
    var onKeyChord: ((KeyChord) -> Bool)? { get set }

    func setEntries(_ entries: [FileEntry], preserveState: Bool)
    func showPlaceholder(_ text: String?)
    func select(name: String)
    func selectNames(_ names: Set<String>)
    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool)
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool)
    func invalidateTagCache()
}

extension PaneContentView {
    /// Grid views don't render tag dots yet, so dropping the cache is a no-op.
    func invalidateTagCache() {}
}

extension FileListController: PaneContentView {
    var keyView: NSView { tableView }
    var onKeyChord: ((KeyChord) -> Bool)? {
        get { tableView.onKeyChord }
        set { tableView.onKeyChord = newValue }
    }
}
