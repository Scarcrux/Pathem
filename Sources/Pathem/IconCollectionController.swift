import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// NSCollectionView that turns key presses into KeyChords (like KeyTableView) and
/// reports activation (double-click / Return) and right-clicks.
@MainActor
final class KeyCollectionView: NSCollectionView {
    var onKeyChord: ((KeyChord) -> Bool)?
    var onBecomeActive: (() -> Void)?
    var onActivate: (() -> Void)?  // double-click or Return on the selection
    var onContextClick: ((IndexPath?) -> Void)?

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
        // Return / Enter opens the selection.
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            super.mouseDown(with: event)  // keep selection in sync
            onActivate?()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        if let indexPath {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
            }
        } else {
            selectionIndexPaths = []
        }
        onContextClick?(indexPath)
        return super.menu(for: event)
    }
}

/// One grid cell: a centered icon over a (possibly two-line) name.
@MainActor
final class IconItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

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
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
        ])
        view = root
    }

    func configure(name: String, image: NSImage, iconSize: CGFloat, fontSize: CGFloat, dimmed: Bool) {
        loadViewIfNeeded()
        icon.image = image
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        label.stringValue = name
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        updateHighlight()
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
    private let iconSize: CGFloat
    private let cellSize: NSSize
    private var labelFontSize: CGFloat = 12

    var directoryURL: URL?
    var resolutionURL: URL?
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?  // grid has no column headers
    var onDropFiles: ((_ urls: [URL], _ move: Bool) -> Void)?

    var keyView: NSView { collection }
    var onKeyChord: ((KeyChord) -> Bool)? {
        get { collection.onKeyChord }
        set { collection.onKeyChord = newValue }
    }

    /// `gallery` uses larger thumbnails than `icon`.
    init(gallery: Bool) {
        iconSize = gallery ? 96 : 56
        cellSize = gallery ? NSSize(width: 150, height: 150) : NSSize(width: 96, height: 92)
        super.init()
        build()
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
        collection.setDraggingSourceOperationMask([.copy], forLocal: false)
        collection.onActivate = { [weak self] in
            guard let self, let first = self.selectedEntries.first else { return }
            self.onOpen?(first)
        }

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
        item.configure(
            name: entry.name, image: image, iconSize: iconSize, fontSize: labelFontSize,
            dimmed: entry.isDataless)
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
        return dir.appendingPathComponent(entry.name) as NSURL
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard !incomingURLs(from: draggingInfo).isEmpty else { return [] }
        proposedDropOperation.pointee = .on
        return resolvedDragOperation(draggingInfo)
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let incoming = incomingURLs(from: draggingInfo)
        guard !incoming.isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(draggingInfo) == .move)
        return true
    }

    private func incomingURLs(from info: NSDraggingInfo) -> [URL] {
        guard let dir = directoryURL,
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        let dirPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                .compare(dirPath, options: .caseInsensitive) != .orderedSame
        }
    }

    private func resolvedDragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        return commandHeld && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    // MARK: Icons

    private static let cloudIcon =
        NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Online only") ?? NSImage()
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
