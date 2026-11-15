import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// Finder-style Gallery view: a large QuickLook preview of the selected item above a
/// horizontal filmstrip of thumbnails. Selecting a thumbnail updates the big preview.
/// (Plain icon view is the grid; this is deliberately different.) Conforms to
/// PaneContentView so PaneController can swap it for the list/icon/column views.
@MainActor
final class GalleryController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSTextFieldDelegate, PaneContentView
{
    let scrollView = NSScrollView()  // the filmstrip's scroller (protocol requirement)
    private let composite = NSView()
    private let preview = QuickLookPreview()  // live Quick Look of the selected item
    private let previewName = NSTextField(labelWithString: "")
    private let filmstrip = KeyCollectionView()
    #if DEBUG
    func debugMatrixFirstVisibleName() -> String? {
        let paths = filmstrip.indexPathsForVisibleItems().sorted {
            (filmstrip.layoutAttributesForItem(at: $0)?.frame.minX ?? 0)
                < (filmstrip.layoutAttributesForItem(at: $1)?.frame.minX ?? 0)
        }
        guard let index = paths.first?.item, entries.indices.contains(index) else { return nil }
        return entries[index].name
    }
    #endif
    private let emptyLabel = NSTextField(labelWithString: "")
    private static let itemID = NSUserInterfaceItemIdentifier("gallery-item")

    private(set) var entries: [FileEntry] = []
    private var labelFontSize: CGFloat = 11
    private var filmstripHeightConstraint: NSLayoutConstraint?
    private var colorRules = ColorRules()
    private var showIconPreviews = true
    func setViewOptions(_ options: FolderViewOptions) {
        let show = options.showIconPreviews ?? true
        guard show != showIconPreviews else { return }
        PaneAppearanceReload.collection(filmstrip, in: scrollView) { showIconPreviews = show }
    }

    /// The committed name of an in-place rename (Finder-style edit in the filmstrip).
    var onInlineRename: ((FileEntry, String) -> Void)?
    /// The entry being renamed in place (nil = not editing); guards commit against reuse/reload.
    private var editingEntry: FileEntry?
    var isInlineEditing: Bool { editingEntry != nil }
    /// Esc pressed during an edit: abandon without committing.
    private var renameCancelled = false

    /// Shared tag-color + git-state cache, so the filmstrip shows the same decorations as the list.
    private let decorations = PaneDecorationCache()

    var directoryURL: URL?
    var resolutionURL: URL?
    var allowsLocalMetadata = true {
        didSet {
            guard allowsLocalMetadata != oldValue else { return }
            if !allowsLocalMetadata {
                decorations.refreshTags(entries: [], directory: nil)
                decorations.setGitStates([:])
                filmstrip.reloadData()
                updatePreview(for: selectedEntries.first ?? entries.first)
            }
            // setEntries will render the new local context; never preview the old remote rows.
        }
    }
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    var dragMovesByDefault = Preferences.default.dragMovesByDefault

    var contentView: NSView { composite }
    var keyView: NSView { filmstrip }
    /// Smoke guard: true iff the filmstrip forwards its focus to the pane (so selecting a gallery
    /// pane makes it active). Was silently false before, unlike list/column/tree.
    var debugForwardsFocusToPane: Bool { filmstrip.onBecomeActive != nil }
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
        // Forward focus so clicking the gallery makes its pane active + focused, like list/tree.
        filmstrip.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.filmstrip.reloadData() }
    }

    /// Right-drag flick + swipe trail (super-drag), forwarded from the filmstrip.
    var onDragSession: ((DragSessionEvent) -> Void)?

    func setGitStates(_ states: [String: GitFileState]) {
        if decorations.setGitStates(allowsLocalMetadata ? states : [:]) { filmstrip.reloadData() }
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
            guard let self,
                let item = (indexPath ?? self.filmstrip.selectionIndexPaths.first)?.item,
                item < self.entries.count
            else { return }
            self.onOpen?(self.entries[item])
        }
        filmstrip.onSelectionMutated = { [weak self] in self?.selectionChanged() }
        contextMenu.selectedURLs = { [weak self] in
            self?.selectedEntries.compactMap { self?.fileURL(for: $0) } ?? []
        }
        contextMenu.currentFolder = { [weak self] in
            guard let self, self.allowsLocalMetadata else { return nil }
            return self.directoryURL
        }
        filmstrip.menu = contextMenu.menu
        scrollView.documentView = filmstrip
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        preview.translatesAutoresizingMaskIntoConstraints = false
        // Let the preview fill the space its constraints give it rather than hugging its content
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
        // A legacy horizontal scroller consumes clip-view height. The old 124pt outer
        // frame left only 109pt for a 104pt item + 16pt insets, triggering AppKit's invalid
        // flow-layout warning and clipping thumbnails. Budget the scroller explicitly.
        let filmstripHeight =
            layout.itemSize.height + layout.sectionInset.top + layout.sectionInset.bottom
            + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 4
        filmstripHeightConstraint = scrollView.heightAnchor.constraint(
            equalToConstant: filmstripHeight)
        filmstripHeightConstraint?.isActive = true
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
        allowsLocalMetadata && !cutPaths.isEmpty
            && cutPaths.contains(PaneItemKey.path(for: entry, in: directoryURL))
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
            if let attrs = filmstrip.layoutAttributesForItem(at: path) {
                union = union.union(attrs.frame)
            }
        }
        guard !union.isNull else { return nil }
        let visible = union.intersection(filmstrip.visibleRect)
        guard !visible.isNull, visible.width > 1 else { return nil }
        return filmstrip.convert(visible, to: nil)
    }

    private func fileURL(for entry: FileEntry) -> URL? {
        guard allowsLocalMetadata else { return nil }
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

    /// Show a large live Quick Look preview of `entry` (scrollable PDFs, playable media,
    /// selectable text, rendered images), falling back to the file icon for folders and
    /// online-only items. This is what makes the gallery a real preview rather than a big icon.
    private func updatePreview(for entry: FileEntry?) {
        guard let entry else {
            preview.show(nil)
            previewName.stringValue = ""
            return
        }
        previewName.stringValue = entry.name
        guard let url = fileURL(for: entry) else {
            preview.show(
                nil, fallbackIcon: entry.isDataless ? Self.cloudIcon : Self.icon(for: entry))
            return
        }
        preview.show(
            url, isDirectory: entry.isDirectory, isDataless: entry.isDataless,
            fallbackIcon: entry.isDataless ? Self.cloudIcon : Self.icon(for: entry))
    }

    // MARK: PaneContentView

    var selectedEntries: [FileEntry] {
        filmstrip.selectionIndexPaths.compactMap {
            $0.item < entries.count ? entries[$0.item] : nil
        }
    }

    // MARK: In-place rename (Finder-style, so New Folder drops straight into editing here too)

    /// Begin editing the single selected filmstrip item's name inline. Returns false when it can't
    /// (nothing or many selected, or the cell isn't realized) so the pane falls back to the sheet.
    func beginInlineRename() -> Bool {
        guard editingEntry == nil else { return false }
        let selected = selectedEntries
        guard selected.count == 1, let entry = selected.first,
            let index = entries.firstIndex(where: { $0.name == entry.name })
        else { return false }
        let path = IndexPath(item: index, section: 0)
        filmstrip.scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
        filmstrip.layoutSubtreeIfNeeded()
        guard let field = (filmstrip.item(at: path) as? IconItem)?.textField else { return false }
        editingEntry = entry
        renameCancelled = false
        field.delegate = self
        field.stringValue = entry.name  // the plain name, without tag-dot / git decoration
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        filmstrip.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let ns = entry.name as NSString
            let ext = ns.pathExtension as NSString
            let baseLength =
                (!entry.isDirectory && ext.length > 0) ? ns.length - ext.length - 1 : ns.length
            editor.selectedRange = NSRange(location: 0, length: max(0, baseLength))
        }
        return true
    }

    private func endInlineEditing(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingMiddle
    }

    /// Abandon an in-progress inline edit without committing (before a reload recycles the cell).
    func cancelInlineEdit() {
        guard let entry = editingEntry else { return }
        editingEntry = nil
        renameCancelled = false
        if let index = entries.firstIndex(where: { $0.name == entry.name }),
            let field = (filmstrip.item(at: IndexPath(item: index, section: 0)) as? IconItem)?
                .textField
        {
            endInlineEditing(field)
            if field.currentEditor() != nil { filmstrip.window?.makeFirstResponder(filmstrip) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        if selector == #selector(NSResponder.cancelOperation(_:)) {  // Esc abandons the edit
            renameCancelled = true
            filmstrip.window?.makeFirstResponder(filmstrip)
            return true
        }
        return false  // let Return / Tab end editing the usual way
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let entry = editingEntry else { return }
        endInlineEditing(field)
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = renameCancelled
        editingEntry = nil
        renameCancelled = false
        if let index = entries.firstIndex(where: { $0.name == entry.name }) {
            filmstrip.reloadItems(at: [IndexPath(item: index, section: 0)])
        }
        guard !cancelled, !newName.isEmpty, newName != entry.name else { return }
        onInlineRename?(entry, newName)
    }

    func setEntries(_ entries: [FileEntry], preserveState: Bool) {
        cancelInlineEdit()  // a background reload must not commit a half-typed rename
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
        decorations.refreshTags(
            entries: allowsLocalMetadata ? entries : [],
            directory: allowsLocalMetadata ? directoryURL : nil)
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
    func setColorRules(_ rules: ColorRules) {
        guard rules != colorRules else { return }
        PaneAppearanceReload.collection(filmstrip, in: scrollView) { colorRules = rules }
    }

    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        PaneAppearanceReload.collection(filmstrip, in: scrollView) {
            labelFontSize = fontSize
            if let layout = filmstrip.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize.height = max(104, 64 + ceil(fontSize * 2) + 12)
                filmstripHeightConstraint?.constant =
                    layout.itemSize.height + layout.sectionInset.top + layout.sectionInset.bottom
                    + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 4
                layout.invalidateLayout()
            }
        }
    }

    // MARK: Data source / selection / drag

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
        -> Int
    {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    )
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! IconItem
        let entry = entries[indexPath.item]
        let thumbnailURL =
            (entry.isDirectory || entry.isDataless || !showIconPreviews) ? nil : fileURL(for: entry)
        let ruleStyle = FileColorStyle.style(
            for: entry, rules: colorRules, baseFont: .systemFont(ofSize: labelFontSize))
        item.configure(
            name: entry.name, image: entry.isDataless ? Self.cloudIcon : Self.icon(for: entry),
            iconSize: 64, fontSize: labelFontSize, dimmed: entry.isDataless,
            thumbnailURL: thumbnailURL,
            git: allowsLocalMetadata ? decorations.gitState(for: entry, in: directoryURL) : nil,
            tags: allowsLocalMetadata ? decorations.tagColors(for: entry, in: directoryURL) : [],
            underlined: indexPath.item == hoveredItem,
            nameFont: ruleStyle?.font, nameColor: ruleStyle?.color,
            accessibilityLabel: FileAXLabel.describe(entry))
        item.view.alphaValue = alpha(for: entry)  // dim cut items until pasted
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        selectionChanged()
    }
    func collectionView(
        _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        selectionChanged()
    }

    func collectionView(
        _ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath
    )
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
        guard FileDrag.hasFileURLs(draggingInfo.draggingPasteboard) else { return [] }
        proposedDropOperation.pointee = .before
        proposedIndexPath.pointee = NSIndexPath(forItem: entries.count, inSection: 0)
        return FileDrag.operation(for: draggingInfo, movesByDefault: dragMovesByDefault)
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let urls = FileDrag.readFileURLs(from: draggingInfo.draggingPasteboard), !urls.isEmpty
        else { return false }
        let operation = FileDrag.operation(for: draggingInfo, movesByDefault: dragMovesByDefault)
        guard !operation.isEmpty else { return false }
        onDropFiles?(urls, operation == .move, nil)
        return true
    }

    private static let cloudIcon =
        NSImage(
            systemSymbolName: "icloud.and.arrow.down",
            accessibilityDescription: L("cloud.notDownloaded", "In iCloud, not downloaded"))
        ?? NSImage()
    private static func icon(for entry: FileEntry) -> NSImage {
        if let themed = IconSetManager.shared.icon(for: entry) { return themed }  // active icon set
        return NSWorkspace.shared.icon(
            for: entry.isDirectory
                ? .folder
                : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data))
    }
}
