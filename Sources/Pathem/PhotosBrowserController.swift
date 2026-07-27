import AppKit
import Photos
import UniformTypeIdentifiers

/// A window that browses the macOS Photos library (albums on the left, a thumbnail grid on the
/// right) and gets photos OUT of it: drag any thumbnail into a folder (a file promise that exports
/// the original), or select and Export. Read-only for now -- edits stay in Photos. Backed entirely
/// by PhotoKit (`PhotoLibrary`), so nothing touches the `.photoslibrary` bundle directly.
@MainActor
final class PhotosBrowserController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSFilePromiseProviderDelegate
{
    private var window: NSWindow?
    private let albumTable = NSTableView()
    private let grid = NSCollectionView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let exportButton = NSButton()
    private let placeholder = NSTextField(labelWithString: "")

    private let imageManager = PHCachingImageManager()
    private static let itemID = NSUserInterfaceItemIdentifier("photo-grid-item")

    private var albums: [PhotoLibrary.Album] = []
    private var assets: PHFetchResult<PHAsset>?

    /// Where exported originals go (the configured torrent-style default: the pane's folder, set by
    /// the caller). Falls back to Downloads.
    var defaultExportDirectory: URL?

    // MARK: - Presentation

    func show(exportDirectory: URL?) {
        defaultExportDirectory = exportDirectory
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loadOrRequestAccess()
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = L("photos.windowTitle", "Photos")
        window.center()
        window.setFrameAutosaveName("com.scarcrux.pathem.photosBrowser")

        albumTable.headerView = nil
        albumTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("album")))
        albumTable.dataSource = self
        albumTable.delegate = self
        albumTable.style = .sourceList
        albumTable.rowHeight = 24
        let albumScroll = NSScrollView()
        albumScroll.documentView = albumTable
        albumScroll.hasVerticalScroller = true
        albumScroll.translatesAutoresizingMaskIntoConstraints = false
        albumScroll.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 120, height: 120)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.register(PhotoGridItem.self, forItemWithIdentifier: Self.itemID)
        grid.setDraggingSourceOperationMask([.copy], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy], forLocal: true)
        let gridScroll = NSScrollView()
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.maximumNumberOfLines = 0
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: gridScroll.widthAnchor, constant: -48),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(albumScroll)
        split.addArrangedSubview(gridScroll)
        split.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        exportButton.title = L("photos.export", "Export…")
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportSelected)
        exportButton.isEnabled = false
        let bar = NSStackView(views: [statusLabel, NSView(), exportButton])
        bar.orientation = .horizontal
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(split)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        self.window = window
    }

    // MARK: - Access + loading

    private func loadOrRequestAccess() {
        let status = PhotoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            loadAlbums()
        case .notDetermined:
            showPlaceholder(L("photos.requesting", "Requesting access to your photo library…"))
            Task { @MainActor in
                _ = await PhotoLibrary.requestAccess()
                if PhotoLibrary.isAuthorized { loadAlbums() } else { showDenied() }
            }
        default:
            showDenied()
        }
    }

    private func showDenied() {
        albums = []
        assets = nil
        albumTable.reloadData()
        grid.reloadData()
        exportButton.isEnabled = false
        showPlaceholder(L(
            "photos.denied",
            "Pathem doesn’t have access to your photo library. Grant it in System Settings ▸ Privacy & Security ▸ Photos."))
    }

    private func loadAlbums() {
        albums = PhotoLibrary.albums()
        albumTable.reloadData()
        if !albums.isEmpty {
            albumTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectAlbum(0)
        } else {
            showPlaceholder(L("photos.empty", "No albums found in your photo library."))
        }
    }

    private func selectAlbum(_ index: Int) {
        guard index >= 0, index < albums.count else { return }
        let album = albums[index]
        let fetched = PhotoLibrary.assets(in: album)
        assets = fetched
        var toCache: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in toCache.append(asset) }
        imageManager.startCachingImages(
            for: toCache, targetSize: NSSize(width: 240, height: 240), contentMode: .aspectFill, options: nil)
        showPlaceholder(nil)
        grid.reloadData()
        grid.scrollToVisible(.zero)
        updateStatus()
    }

    private func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    private func updateStatus() {
        let total = assets?.count ?? 0
        let selected = grid.selectionIndexPaths.count
        exportButton.isEnabled = selected > 0
        statusLabel.stringValue = selected > 0
            ? String(format: L("photos.statusSelected", "%d of %d selected"), selected, total)
            : String(format: L("photos.statusCount", "%d items"), total)
    }

    private func asset(at indexPath: IndexPath) -> PHAsset? {
        guard let assets, indexPath.item < assets.count else { return nil }
        return assets.object(at: indexPath.item)
    }

    // MARK: - NSTableView (albums)

    func numberOfRows(in tableView: NSTableView) -> Int { albums.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("album-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            cell.identifier = id
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let album = albums[row]
        cell.textField?.stringValue = "\(album.title)  (\(album.count))"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectAlbum(albumTable.selectedRow)
    }

    // MARK: - NSCollectionView (thumbnails)

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        assets?.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! PhotoGridItem
        guard let asset = asset(at: indexPath) else { return item }
        item.represent(asset, manager: imageManager)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
    }

    /// Drag-out: each dragged thumbnail is a file promise that exports the asset's original when it's
    /// dropped into a folder (Pathem, Finder, anywhere that accepts a promise).
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath)
        -> NSPasteboardWriting?
    {
        guard let asset = asset(at: indexPath) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let uti = PhotoLibrary.primaryResource(resources)?.uniformTypeIdentifier ?? UTType.item.identifier
        let provider = NSFilePromiseProvider(fileType: uti, delegate: self)
        provider.userInfo = asset.localIdentifier
        return provider
    }

    // MARK: - NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let id = provider.userInfo as? String, let asset = PhotoLibrary.asset(withID: id) else { return "photo" }
        return PhotoLibrary.originalFilename(for: asset)
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        OperationQueue()  // a fresh queue per promise; AppKit retains it for the write
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let id = provider.userInfo as? String
        Task {
            guard let id else { completionHandler(PhotoLibrary.ExportError.noResource); return }
            do {
                try await PhotoLibrary.writeOriginal(assetID: id, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    // MARK: - Export button

    @objc private func exportSelected() {
        let ids = grid.selectionIndexPaths.sorted().compactMap { asset(at: $0)?.localIdentifier }
        guard !ids.isEmpty, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("photos.exportHere", "Export Here")
        panel.directoryURL = defaultExportDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            self.exportAssets(ids, to: directory)
        }
    }

    private func exportAssets(_ ids: [String], to directory: URL) {
        statusLabel.stringValue = String(format: L("photos.exporting", "Exporting %d…"), ids.count)
        Task { @MainActor in
            var failures = 0
            for id in ids {
                do { _ = try await PhotoLibrary.exportOriginal(assetID: id, to: directory) } catch { failures += 1 }
            }
            statusLabel.stringValue = failures == 0
                ? String(format: L("photos.exported", "Exported %d"), ids.count)
                : String(format: L("photos.exportedWithErrors", "Exported %d, %d failed"), ids.count - failures, failures)
            updateStatusAfterDelay()
        }
    }

    private func updateStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.updateStatus() }
    }
}

/// One thumbnail cell: an image view that requests its PhotoKit thumbnail and cancels a stale request
/// on reuse.
@MainActor
final class PhotoGridItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private var requestID: PHImageRequestID?
    private weak var manager: PHCachingImageManager?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 4
        root.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        imageView = thumb
        view = root
    }

    func represent(_ asset: PHAsset, manager: PHCachingImageManager) {
        loadViewIfNeeded()
        self.manager = manager
        if let requestID { manager.cancelImageRequest(requestID) }
        thumb.image = nil
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let local = asset.localIdentifier
        requestID = manager.requestImage(
            for: asset, targetSize: NSSize(width: 240, height: 240), contentMode: .aspectFill, options: options
        ) { [weak self] image, info in
            guard let self, let image else { return }
            // Ignore a late callback for a recycled cell.
            let current = (self.representedObject as? String) ?? local
            if current == local { self.thumb.image = image }
        }
        representedObject = local
    }

    override var isSelected: Bool {
        didSet { view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = ThemeManager.shared.accent.cgColor }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let requestID { manager?.cancelImageRequest(requestID) }
        requestID = nil
        thumb.image = nil
    }
}
