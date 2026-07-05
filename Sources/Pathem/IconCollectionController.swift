import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// NSCollectionView that turns key presses into KeyChords (like KeyTableView) and
/// reports activation (double-click / Return) and right-clicks.
@MainActor
final class KeyCollectionView: NSCollectionView {
    var onKeyChord: ((KeyChord) -> Bool)?
    var onMouseGesture: ((String) -> Bool)?
    /// Cmd-scroll zoom: reports the vertical scroll delta when Command is held.
    var onZoom: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onZoom?(event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY)
            return
        }
        super.scrollWheel(with: event)
    }
    var onBecomeActive: (() -> Void)?

    private let gestureTracker = MouseGestureTracker()

    override func rightMouseDown(with event: NSEvent) { gestureTracker.begin(event) }
    override func rightMouseDragged(with event: NSEvent) { gestureTracker.append(event) }
    override func rightMouseUp(with event: NSEvent) {
        if let stroke = gestureTracker.end(event), onMouseGesture?(stroke) == true { return }
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    /// Double-click (carries the clicked item) or Return (nil = the selection).
    var onActivate: ((IndexPath?) -> Void)?
    /// Called when a right-click changes the selection (programmatic selection
    /// changes don't fire the delegate's didSelect/didDeselect).
    var onSelectionMutated: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeActive?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let chord = KeyChord.from(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            cmd: flags.contains(.command), opt: flags.contains(.option),
            ctrl: flags.contains(.control), shift: flags.contains(.shift))
        if onKeyChord?(chord) == true { return }
        if event.keyCode == 36 || event.keyCode == 76 {  // Return / Enter
            onActivate?(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
            super.mouseDown(with: event)  // keep selection in sync
            onActivate?(indexPath)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let before = selectionIndexPaths
        if let indexPath = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(indexPath) { selectionIndexPaths = [indexPath] }
        } else {
            selectionIndexPaths = []
        }
        // Programmatic selection changes don't fire the delegate, so the controller's
        // selection (and the menu's enabled actions) would otherwise go stale.
        if selectionIndexPaths != before { onSelectionMutated?() }
        return super.menu(for: event)
    }
}

/// One grid cell: a centered icon over a (possibly two-line) name.
@MainActor
final class IconItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    /// The file this cell is showing; guards an async thumbnail against cell reuse.
    private var representedURL: URL?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = true
        root.addSubview(icon)
        root.addSubview(label)
        imageView = icon
        textField = label
        // Size constraints created once and updated in configure(), so reused
        // cells never accumulate duplicate constraints.
        let w = icon.widthAnchor.constraint(equalToConstant: 56)
        let h = icon.heightAnchor.constraint(equalToConstant: 56)
        iconWidth = w
        iconHeight = h
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            w, h,
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
        ])
        view = root
    }

    func configure(
        name: String, image: NSImage, iconSize: CGFloat, fontSize: CGFloat, dimmed: Bool,
        thumbnailURL: URL?
    ) {
        loadViewIfNeeded()
        icon.image = image  // type icon shows immediately; a thumbnail replaces it when ready
        iconWidth?.constant = iconSize
        iconHeight?.constant = iconSize
        label.stringValue = name
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        updateHighlight()

        representedURL = thumbnailURL
        guard let url = thumbnailURL else { return }
        let size = CGSize(width: iconSize, height: iconSize)
        if let hit = ThumbnailProvider.shared.cached(url, size: size) {
            icon.image = hit
            return
        }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ThumbnailProvider.shared.generate(url, size: size, scale: scale) { [weak self] image in
            guard let self, self.representedURL == url else { return }  // cell wasn't reused
            self.icon.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil  // ignore any in-flight thumbnail for the previous file
    }

    override var isSelected: Bool { didSet { updateHighlight() } }

    private func updateHighlight() {
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor =
            isSelected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
    }
}

/// Icon and gallery views, both NSCollectionView (gallery uses larger thumbnails).
/// Conforms to PaneContentView so PaneController can swap it for the list.
@MainActor
final class IconCollectionController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
    PaneContentView
{
    let scrollView = NSScrollView()
    private let collection = KeyCollectionView()
    private let placeholder = NSTextField(labelWithString: "")
    private static let itemID = NSUserInterfaceItemIdentifier("icon-item")

    private(set) var entries: [FileEntry] = []
    private let gallery: Bool
    private var scale: CGFloat = 1
    private var baseIconSize: CGFloat { gallery ? 96 : 56 }
    private var iconSize: CGFloat { (baseIconSize * scale).rounded() }
    private var cellSize: NSSize {
        let side = iconSize
        return gallery
            ? NSSize(width: side + 54, height: side + 54)
            : NSSize(width: side + 40, height: side + 36)
    }
    private var labelFontSize: CGFloat = 12
    /// Reports a new zoom scale so the pane can persist it across view switches/launches.
    var onZoomChanged: ((CGFloat) -> Void)?

    var directoryURL: URL?
    var resolutionURL: URL?
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?  // grid has no column headers
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?

    var keyView: NSView { collection }
    var onKeyChord: ((KeyChord) -> Bool)? {
        get { collection.onKeyChord }
        set { collection.onKeyChord = newValue }
    }
    var onMouseGesture: ((String) -> Bool)? {
        get { collection.onMouseGesture }
        set { collection.onMouseGesture = newValue }
    }

    /// `gallery` uses larger thumbnails than `icon`. `scale` zooms both (1 = default).
    init(gallery: Bool, scale: CGFloat = 1) {
        self.gallery = gallery
        self.scale = min(max(scale, 0.5), 3.0)
        super.init()
        build()
        collection.onZoom = { [weak self] delta in self?.adjustZoom(delta * 0.0125) }  // Cmd-scroll
    }

    /// Zoom by an absolute step (Cmd +/-) or a scroll-derived delta; clamps and persists.
    func adjustZoom(_ delta: CGFloat) {
        let next = min(max(scale + delta, 0.5), 3.0)
        guard abs(next - scale) > 0.001 else { return }
        scale = next
        if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = cellSize
            layout.invalidateLayout()
        }
        collection.reloadData()  // re-request thumbnails at the new size
        onZoomChanged?(scale)
    }

    private func build() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = cellSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(IconItem.self, forItemWithIdentifier: Self.itemID)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask(.every, forLocal: false)  // effectAllowed="all", like Finder
        collection.onActivate = { [weak self] indexPath in
            guard let self else { return }
            if let indexPath, indexPath.item < self.entries.count {
                self.onOpen?(self.entries[indexPath.item])  // the double-clicked item
            } else if let first = self.selectedEntries.first {
                self.onOpen?(first)  // Return with a selection
            }
        }
        collection.onSelectionMutated = { [weak self] in self?.onSelectionChanged?() }
        collection.menu = makeContextMenu()

        scrollView.documentView = collection
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.maximumNumberOfLines = 0
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    /// Right-click menu mirroring the list's (registry commands dispatched up the
    /// responder chain to BrowserViewController). Open With is list-only for now.
    /// Command ids hidden from the context menu (from the Settings ▸ Menus preference),
    /// honored the same way the list view does so the reveal/hide choice applies everywhere.
    private var hiddenContextItems: Set<String> = []
    func setHiddenContextItems(_ ids: Set<String>) {
        guard ids != hiddenContextItems else { return }
        hiddenContextItems = ids
        collection.menu = makeContextMenu()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ id: String) {
            guard !hiddenContextItems.contains(id) else { return }
            let item = NSMenuItem(
                title: title, action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
            item.representedObject = id
            item.image = MenuIcons.image(forCommand: id)
            menu.addItem(item)
        }
        add(L("common.open", "Open"), "files.open")
        add(L("icons.getInfo", "Get Info"), "files.getInfo")
        add(L("icons.download", "Download"), "files.download")
        add(L("icons.revealInFinder", "Reveal in Finder"), "files.reveal")
        add(L("icons.revealInPathem", "Reveal in Pathem"), "files.revealInPathem")
        add(L("icons.rename", "Rename…"), "files.rename")
        add(L("icons.moveToTrash", "Move to Trash"), "files.trash")
        menu.addItem(.separator())
        add(L("icons.newFolder", "New Folder"), "files.newFolder")
        add(L("bvc.cmd.newFile", "New File"), "files.newFile")
        menu.addItem(.separator())
        add(L("icons.copy", "Copy"), "files.copy")
        add(L("icons.cut", "Cut"), "files.cut")
        add(L("icons.paste", "Paste"), "files.paste")
        return menu
    }

    var selectedEntries: [FileEntry] {
        collection.selectionIndexPaths.compactMap { $0.item < entries.count ? entries[$0.item] : nil }
    }

    func setEntries(_ entries: [FileEntry], preserveState: Bool) {
        let selectedNames = preserveState ? Set(selectedEntries.map(\.name)) : []
        self.entries = entries
        collection.reloadData()
        if !selectedNames.isEmpty {
            var paths = Set<IndexPath>()
            for (index, entry) in entries.enumerated() where selectedNames.contains(entry.name) {
                paths.insert(IndexPath(item: index, section: 0))
            }
            collection.selectionIndexPaths = paths
        }
    }

    func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    func select(name: String) {
        guard let index = entries.firstIndex(where: { $0.name == name }) else { return }
        let path = IndexPath(item: index, section: 0)
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: .centeredVertically)
    }

    func selectNames(_ names: Set<String>) {
        var paths = Set<IndexPath>()
        for (index, entry) in entries.enumerated() where names.contains(entry.name) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        collection.selectionIndexPaths = paths
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}  // no headers in a grid

    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        labelFontSize = fontSize
        collection.reloadData()
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! IconItem
        let entry = entries[indexPath.item]
        let image = entry.isDataless ? Self.cloudIcon : Self.icon(for: entry)
        // Real content thumbnails for files only; never for folders or online-only
        // (dataless) items, where generating one could fault a download.
        let thumbnailURL = (entry.isDirectory || entry.isDataless) ? nil : fileURL(for: entry)
        item.configure(
            name: entry.name, image: image, iconSize: iconSize, fontSize: labelFontSize,
            dimmed: entry.isDataless, thumbnailURL: thumbnailURL)
        // Dim hidden (dotfile) items so they read as hidden when "show hidden files" is on,
        // as Finder does. Set on every configure (cells are reused) so it never sticks.
        item.view.alphaValue = entry.isHidden ? 0.5 : 1.0
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged?()
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath)
        -> NSPasteboardWriting?
    {
        guard let dir = directoryURL, indexPath.item < entries.count else { return nil }
        let entry = entries[indexPath.item]
        guard !entry.isDataless else { return nil }
        return FileDrag.item(for: dir.appendingPathComponent(entry.name))  // promise + file URL
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let dir = directoryURL else { return }
        let urls = indexPaths.compactMap { path -> URL? in
            guard path.item < entries.count, !entries[path.item].isDataless else { return nil }
            return dir.appendingPathComponent(entries[path.item].name)
        }
        FileDrag.addLegacyFilenames(urls, to: session.draggingPasteboard)
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard let urls = draggedURLs(from: draggingInfo), !urls.isEmpty else { return [] }
        // Over a folder item -> drop ONTO it (highlighted). Else a "before end" drop into
        // this folder so drops onto empty grid space are still delivered to acceptDrop.
        if let path = folderIndexPath(under: draggingInfo, in: collectionView, excluding: urls) {
            proposedDropOperation.pointee = .on
            proposedIndexPath.pointee = path as NSIndexPath
        } else {
            guard !incomingURLs(urls, into: directoryURL).isEmpty else { return [] }
            proposedDropOperation.pointee = .before
            proposedIndexPath.pointee = NSIndexPath(forItem: entries.count, inSection: 0)
        }
        return resolvedDragOperation(draggingInfo)
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let urls = draggedURLs(from: draggingInfo), !urls.isEmpty else { return false }
        var folder: URL?
        if dropOperation == .on, indexPath.item < entries.count, entries[indexPath.item].isDirectory {
            folder = fileURL(for: entries[indexPath.item])
        }
        let incoming = incomingURLs(urls, into: folder ?? directoryURL)
        guard !incoming.isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(draggingInfo) == .move, folder)
        return true
    }

    /// The index path of a folder item under the drag (not one of the dragged items).
    private func folderIndexPath(
        under info: NSDraggingInfo, in collectionView: NSCollectionView, excluding dragged: [URL]
    ) -> IndexPath? {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        guard let path = collectionView.indexPathForItem(at: point), path.item < entries.count,
            entries[path.item].isDirectory, let folder = fileURL(for: entries[path.item])
        else { return nil }
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if dragged.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == folderPath }) {
            return nil  // don't drop a folder onto itself
        }
        return path
    }

    /// The on-disk URL of an entry (smart-result rows carry their own folder).
    private func fileURL(for entry: FileEntry) -> URL? {
        if let location = entry.location {
            return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
        }
        return directoryURL?.appendingPathComponent(entry.name)
    }

    private func draggedURLs(from info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    private func incomingURLs(_ urls: [URL], into destination: URL?) -> [URL] {
        guard let destination else { return [] }
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                .compare(destPath, options: .caseInsensitive) != .orderedSame
        }
    }

    private func resolvedDragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        return commandHeld && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    // MARK: Icons

    private static let cloudIcon =
        NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: L("icons.onlineOnly", "Online only")) ?? NSImage()
    private static var iconCache: [String: NSImage] = [:]

    private static func icon(for entry: FileEntry) -> NSImage {
        let key = entry.isDirectory ? "\u{0}folder" : (entry.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let workspace = NSWorkspace.shared
        let image: NSImage
        if entry.isDirectory {
            image = workspace.icon(for: .folder)
        } else if !key.isEmpty, let type = UTType(filenameExtension: key) {
            image = workspace.icon(for: type)
        } else {
            image = workspace.icon(for: .data)
        }
        iconCache[key] = image
        return image
    }
}
