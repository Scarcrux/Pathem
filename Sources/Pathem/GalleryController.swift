import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// Finder-style Gallery view: a large QuickLook preview of the selected item above a
/// horizontal filmstrip of thumbnails. Selecting a thumbnail updates the big preview.
/// (Plain icon view is the grid; this is deliberately different.) Conforms to
/// PaneContentView so PaneController can swap it for the list/icon/column views.
@MainActor
final class GalleryController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
    PaneContentView
{
    let scrollView = NSScrollView()  // the filmstrip's scroller (protocol requirement)
    private let composite = NSView()
    private let preview = NSImageView()  // large preview of the selected item
    private let previewName = NSTextField(labelWithString: "")
    private let filmstrip = KeyCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private static let itemID = NSUserInterfaceItemIdentifier("gallery-item")

    private(set) var entries: [FileEntry] = []
    private var labelFontSize: CGFloat = 11
    private var previewURL: URL?  // guards an async thumbnail against a newer selection

    /// Shared tag-color + git-state cache, so the filmstrip shows the same decorations as the list.
    private let decorations = PaneDecorationCache()

    var directoryURL: URL?
    var resolutionURL: URL?
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var dragMovesByDefault = false

    var contentView: NSView { composite }
    var keyView: NSView { filmstrip }
    var onKeyChord: ((KeyChord) -> Bool)? {
        get { filmstrip.onKeyChord }
        set { filmstrip.onKeyChord = newValue }
    }
    var onMouseGesture: ((String) -> Bool)? {
        get { filmstrip.onMouseGesture }
        set { filmstrip.onMouseGesture = newValue }
    }

    override init() {
        super.init()
        build()
        decorations.onTagsChanged = { [weak self] in self?.filmstrip.reloadData() }
        filmstrip.onHover = { [weak self] indexPath in self?.setHovered(indexPath?.item ?? -1) }
        filmstrip.onSuperDrag = { [weak self] event in self?.onDragSession?(event) }
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.filmstrip.reloadData() }
    }

    /// Right-drag flick + swipe trail (super-drag), forwarded from the filmstrip.
    var onDragSession: ((DragSessionEvent) -> Void)?

    func setGitStates(_ states: [String: GitFileState]) {
        if decorations.setGitStates(states) { filmstrip.reloadData() }
    }

    func invalidateTagCache() { decorations.invalidateTags() }

    func setBackgroundColor(_ color: NSColor?) {
        let transparent = (color?.alphaComponent ?? 1) < 0.02
        scrollView.backgroundColor = transparent ? .clear : (color ?? .controlBackgroundColor)
        scrollView.drawsBackground = !transparent
    }

    /// Which filmstrip item the pointer is over (-1 = none), underlined when hover-to-open is on.
    private var hoveredItem = -1

    private func setHovered(_ index: Int) {
        guard index != hoveredItem else { return }
        let old = hoveredItem
        hoveredItem = index
        var paths = Set<IndexPath>()
        if old >= 0, old < entries.count { paths.insert(IndexPath(item: old, section: 0)) }
        if index >= 0, index < entries.count { paths.insert(IndexPath(item: index, section: 0)) }
        if !paths.isEmpty { filmstrip.reloadItems(at: paths) }
    }

    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        filmstrip.singleClickToOpen = singleClick
        filmstrip.setHoverTracking(underlineHover)
        if !underlineHover { setHovered(-1) }
    }

    private func build() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 92, height: 104)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        filmstrip.collectionViewLayout = layout
        filmstrip.dataSource = self
        filmstrip.delegate = self
        filmstrip.isSelectable = true
        filmstrip.allowsMultipleSelection = true
        filmstrip.allowsEmptySelection = true
        filmstrip.backgroundColors = [.clear]
        filmstrip.register(IconItem.self, forItemWithIdentifier: Self.itemID)
        filmstrip.registerForDraggedTypes([.fileURL])
        filmstrip.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        filmstrip.setDraggingSourceOperationMask(.every, forLocal: false)  // effectAllowed="all", like Finder
        filmstrip.onActivate = { [weak self] indexPath in
            guard let self, let item = (indexPath ?? self.filmstrip.selectionIndexPaths.first)?.item,
                item < self.entries.count
            else { return }
            self.onOpen?(self.entries[item])
        }
        filmstrip.onSelectionMutated = { [weak self] in self?.selectionChanged() }
        contextMenu.selectedURLs = { [weak self] in
            self?.selectedEntries.compactMap { self?.fileURL(for: $0) } ?? []
        }
        filmstrip.menu = contextMenu.menu
        scrollView.documentView = filmstrip
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        // Let the preview fill the space its constraints give it rather than hugging its image
        // size; otherwise the whole composite collapses to content height and bottom-aligns.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            preview.setContentHuggingPriority(.defaultLow, for: axis)
            preview.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        previewName.translatesAutoresizingMaskIntoConstraints = false
        previewName.alignment = .center
        previewName.font = .systemFont(ofSize: 13)
        previewName.textColor = .secondaryLabelColor
        previewName.lineBreakMode = .byTruncatingMiddle

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        composite.addSubview(preview)
        composite.addSubview(previewName)
        composite.addSubview(scrollView)
        composite.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: composite.topAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: composite.leadingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: composite.trailingAnchor, constant: -16),
            preview.bottomAnchor.constraint(equalTo: previewName.topAnchor, constant: -8),
            previewName.leadingAnchor.constraint(equalTo: composite.leadingAnchor, constant: 16),
            previewName.trailingAnchor.constraint(equalTo: composite.trailingAnchor, constant: -16),
            previewName.bottomAnchor.constraint(equalTo: scrollView.topAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: composite.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: composite.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composite.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 124),  // single thumbnail row
            emptyLabel.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
        ])
        // The composite is "size-indifferent" (the preview scales to whatever space it gets),
        // so on its own it collapses to content height and its pane stops filling. A low-priority
        // tall height makes it actively claim vertical space, like a scroll view does, while the
        // required edge pins still cap it at the pane's height.
        let fill = composite.heightAnchor.constraint(equalToConstant: 4000)
        fill.priority = .defaultLow
        fill.isActive = true
    }

    /// The one shared file context menu, identical across every pane view so the gallery
    /// gains Open With, Tags, New Folder, clipboard, and Extract instead of its old reduced
    /// set. Honors the Settings ▸ Menus hide/show choice.
    private let contextMenu = FileContextMenuController()
    func setHiddenContextItems(_ ids: Set<String>) { contextMenu.hiddenItems = ids }
    func setContextMenuOrder(_ order: [String]) { contextMenu.menuOrder = order }

    // MARK: - Cut dimming + selection anchor (parity with the list view)

    private var cutPaths: Set<String> = []
    private func isCut(_ entry: FileEntry) -> Bool {
        !cutPaths.isEmpty && cutPaths.contains(PaneItemKey.path(for: entry, in: directoryURL))
    }
    private func alpha(for entry: FileEntry) -> CGFloat { isCut(entry) ? 0.45 : 1.0 }

    func setCutPaths(_ paths: Set<String>) {
        guard paths != cutPaths else { return }
        let changed = paths.symmetricDifference(cutPaths)
        cutPaths = paths
        for (i, entry) in entries.enumerated()
        where changed.contains(PaneItemKey.path(for: entry, in: directoryURL)) {
            (filmstrip.item(at: IndexPath(item: i, section: 0)) as? IconItem)?.view.alphaValue =
                alpha(for: entry)
        }
    }

    /// The selected thumbnails' bounding rect in window coordinates, so the quick-actions bar
    /// anchors to them rather than centering on the pane.
    func selectionRectInWindow() -> NSRect? {
        let paths = filmstrip.selectionIndexPaths
        guard !paths.isEmpty else { return nil }
        var union = NSRect.null
        for path in paths {
            if let attrs = filmstrip.layoutAttributesForItem(at: path) { union = union.union(attrs.frame) }
        }
        guard !union.isNull else { return nil }
        let visible = union.intersection(filmstrip.visibleRect)
        guard !visible.isNull, visible.width > 1 else { return nil }
        return filmstrip.convert(visible, to: nil)
    }

    private func fileURL(for entry: FileEntry) -> URL? {
        if let location = entry.location {
            return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
        }
        return directoryURL?.appendingPathComponent(entry.name)
    }

    private func selectionChanged() {
        let selected = selectedEntries.first ?? entries.first
        updatePreview(for: selected)
        onSelectionChanged?()
    }

    /// Show a large preview of `entry`: its real thumbnail when available, else its file
    /// icon. Async thumbnail generation is guarded against a newer selection.
    private func updatePreview(for entry: FileEntry?) {
        guard let entry, let url = fileURL(for: entry) else {
            preview.image = nil
            previewName.stringValue = ""
            previewURL = nil
            return
        }
        previewURL = url
        previewName.stringValue = entry.name
        let fallback = entry.isDataless ? Self.cloudIcon : Self.icon(for: entry)
        preview.image = fallback
        guard !entry.isDirectory, !entry.isDataless else { return }
        let size = CGSize(width: 512, height: 512)
        if let cached = ThumbnailProvider.shared.cached(url, size: size) {
            preview.image = cached
            return
        }
        let scale = preview.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ThumbnailProvider.shared.generate(url, size: size, scale: scale) { [weak self] image in
            guard let self, self.previewURL == url else { return }
            self.preview.image = image
        }
    }

    // MARK: PaneContentView

    var selectedEntries: [FileEntry] {
        filmstrip.selectionIndexPaths.compactMap { $0.item < entries.count ? entries[$0.item] : nil }
    }

    func setEntries(_ entries: [FileEntry], preserveState: Bool) {
        let selectedNames = preserveState ? Set(selectedEntries.map(\.name)) : []
        self.entries = entries
        filmstrip.reloadData()
        var paths = Set<IndexPath>()
        for (index, entry) in entries.enumerated() where selectedNames.contains(entry.name) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        if paths.isEmpty, !entries.isEmpty { paths = [IndexPath(item: 0, section: 0)] }  // preview the first
        filmstrip.selectionIndexPaths = paths
        selectionChanged()
        decorations.refreshTags(entries: entries, directory: directoryURL)
    }

    func showPlaceholder(_ text: String?) {
        emptyLabel.stringValue = text ?? ""
        emptyLabel.isHidden = text == nil
    }

    func select(name: String) {
        guard let index = entries.firstIndex(where: { $0.name == name }) else { return }
        let path = IndexPath(item: index, section: 0)
        filmstrip.selectionIndexPaths = [path]
        filmstrip.scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
        selectionChanged()
    }

    func selectNames(_ names: Set<String>) {
        var paths = Set<IndexPath>()
        for (index, entry) in entries.enumerated() where names.contains(entry.name) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        filmstrip.selectionIndexPaths = paths
        selectionChanged()
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        labelFontSize = fontSize
        filmstrip.reloadData()
    }

    // MARK: Data source / selection / drag

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! IconItem
        let entry = entries[indexPath.item]
        let thumbnailURL = (entry.isDirectory || entry.isDataless) ? nil : fileURL(for: entry)
        item.configure(
            name: entry.name, image: entry.isDataless ? Self.cloudIcon : Self.icon(for: entry),
            iconSize: 64, fontSize: labelFontSize, dimmed: entry.isDataless, thumbnailURL: thumbnailURL,
            git: decorations.gitState(for: entry, in: directoryURL),
            tags: decorations.tagColors(for: entry, in: directoryURL),
            underlined: indexPath.item == hoveredItem)
        item.view.alphaValue = alpha(for: entry)  // dim cut items until pasted
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath)
        -> NSPasteboardWriting?
    {
        guard indexPath.item < entries.count, !entries[indexPath.item].isDataless,
            let url = fileURL(for: entries[indexPath.item])
        else { return nil }
        return FileDrag.item(for: url)  // promise + file URL, so browser upload zones accept it
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>
    ) {
        let urls = indexPaths.compactMap { path -> URL? in
            guard path.item < entries.count, !entries[path.item].isDataless else { return nil }
            return fileURL(for: entries[path.item])
        }
        FileDrag.addLegacyFilenames(urls, to: session.draggingPasteboard)
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        proposedDropOperation.pointee = .before
        proposedIndexPath.pointee = NSIndexPath(forItem: entries.count, inSection: 0)
        return dropMovesByDefault(draggingInfo) ? .move : .copy
    }

    /// Move by default (else copy) between folders, with Command inverting it, matching the list.
    private func dropMovesByDefault(_ info: NSDraggingInfo) -> Bool {
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        return (dragMovesByDefault != commandHeld) && info.draggingSourceOperationMask.contains(.move)
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        else { return false }
        onDropFiles?(urls, dropMovesByDefault(draggingInfo), nil)
        return true
    }

    private static let cloudIcon = NSImage(
        systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil) ?? NSImage()
    private static func icon(for entry: FileEntry) -> NSImage {
        if let themed = IconSetManager.shared.icon(for: entry) { return themed }  // active icon set
        return NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data))
    }
}
