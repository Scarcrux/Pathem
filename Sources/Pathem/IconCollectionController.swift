import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// NSCollectionView that turns key presses into KeyChords (like KeyTableView) and
/// reports activation (double-click / Return) and right-clicks.
@MainActor
final class KeyCollectionView: NSCollectionView {
    private(set) var debugKeyDownCount = 0
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
    /// A right-drag that started on an item: the super-drag flick + its swipe trail. Kept on the
    /// right button so it never collides with a left-drag (normal drag-and-drop), matching the list.
    var onSuperDrag: ((DragSessionEvent) -> Void)?
    private var superDragStartItem: IndexPath?
    private var superDragStartWindow: NSPoint?

    override func rightMouseDown(with event: NSEvent) {
        gestureTracker.begin(event)
        superDragStartWindow = event.locationInWindow
        superDragStartItem = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if let item = superDragStartItem, !selectionIndexPaths.contains(item) {
            selectionIndexPaths = [item]  // the flick acts on it
            onSelectionMutated?()
        }
        // Draw the trail for any right-drag; the flick hint shows only for an item super-drag.
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.began(screen: screen, showsHint: superDragStartItem != nil))
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        gestureTracker.append(event)
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.moved(screen: screen))
        }
    }
    override func rightMouseUp(with event: NSEvent) {
        let navStroke = gestureTracker.end(event)
        if superDragStartItem != nil {
            let flick =
                superDragStartWindow.map {
                    MouseGesture.reduce([$0, event.locationInWindow], minSegment: 44)
                } ?? ""
            onSuperDrag?(.ended(flick: flick.isEmpty ? nil : flick))
            superDragStartItem = nil
            superDragStartWindow = nil
            if flick.isEmpty, let menu = menu(for: event) {  // no flick: a plain right-click
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        onSuperDrag?(.ended(flick: nil))  // end the empty-space trail; the stroke/menu runs below
        superDragStartWindow = nil
        if let stroke = navStroke, onMouseGesture?(stroke) == true { return }
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    /// Double-click (carries the clicked item) or Return (nil = the selection).
    var onActivate: ((IndexPath?) -> Void)?
    /// Called when a right-click changes the selection (programmatic selection
    /// changes don't fire the delegate's didSelect/didDeselect).
    var onSelectionMutated: (() -> Void)?
    /// Open on a single click (Finder's "single click to open" behavior) when set.
    var singleClickToOpen = false
    /// Reports the item under the pointer (nil when outside any item) for hover underlining.
    var onHover: ((IndexPath?) -> Void)?
    private var hoverArea: NSTrackingArea?

    /// Turn hover tracking on/off; when on, `onHover` fires as the pointer moves over items.
    func setHoverTracking(_ on: Bool) {
        if on, hoverArea == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        } else if !on, let area = hoverArea {
            removeTrackingArea(area)
            hoverArea = nil
            onHover?(nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(indexPathForItem(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    /// A drag left the grid or ended; cancels a pending spring-loaded-folder open.
    var onDragExited: (() -> Void)?
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }
    // @objc + no super: draggingEnded: is an optional NSDraggingDestination method NSView doesn't
    // implement, so a plain override isn't exposed to ObjC and AppKit's drag completion hits an
    // unrecognized selector that strands every later drag. See KeyTableView.draggingEnded.
    @objc override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeActive?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        #if DEBUG
        debugKeyDownCount += 1
        #endif
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
        let start = event.locationInWindow
        super.mouseDown(with: event)  // runs the selection/drag tracking loop until mouse-up
        // Single-click-to-open: after the loop, treat a click that barely moved (not a drag) on an
        // item as an open, matching Finder's "single click to open" preference.
        if singleClickToOpen {
            let end = window?.mouseLocationOutsideOfEventStream ?? start
            if hypot(end.x - start.x, end.y - start.y) < 4,
                let indexPath = indexPathForItem(at: convert(start, from: nil))
            {
                onActivate?(indexPath)
            }
        }
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
    private var positionConstraints: [NSLayoutConstraint] = []
    private var position: FolderViewOptions.LabelPosition?

    private func setLabelPosition(_ next: FolderViewOptions.LabelPosition) {
        guard position != next else { return }
        position = next
        NSLayoutConstraint.deactivate(positionConstraints)
        if next == .right {
            label.alignment = .left
            positionConstraints = [
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ]
        } else {
            label.alignment = .center
            positionConstraints = [
                icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            ]
        }
        NSLayoutConstraint.activate(positionConstraints)
    }
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
            w, h,
        ])
        view = root
        setLabelPosition(.below)
    }

    func configure(
        name: String, image: NSImage, iconSize: CGFloat, fontSize: CGFloat, dimmed: Bool,
        thumbnailURL: URL?, git: GitFileState? = nil, tags: [FileTag.Color] = [],
        underlined: Bool = false,
        nameFont: NSFont? = nil, nameColor: NSColor? = nil, accessibilityLabel: String? = nil,
        labelPosition: FolderViewOptions.LabelPosition = .below
    ) {
        loadViewIfNeeded()
        setLabelPosition(labelPosition)
        // Clear any in-place-edit appearance in case this cell was reused mid-rename.
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        icon.image = image  // type icon shows immediately; a thumbnail replaces it when ready
        iconWidth?.constant = iconSize
        iconHeight?.constant = iconSize
        let font = nameFont ?? .systemFont(ofSize: fontSize)  // a color rule can style the name
        label.font = font
        label.textColor = nameColor ?? (dimmed ? .secondaryLabelColor : .labelColor)
        // Middle truncation keeps both the leading git letter and the trailing tag dots even when
        // a long name is clipped, so the grid shows the same decorations as the list and column.
        if git != nil || !tags.isEmpty {
            let decorated = FileNameDecoration.decoratedName(
                name, git: git, dots: tags, size: fontSize, nameFont: nameFont, nameColor: nameColor
            )
            // An attributed name carries its own paragraph style, so without this a tagged
            // name sits left-aligned under the icon while untagged ones are centred.
            let aligned = NSMutableAttributedString(
                attributedString: underlined ? Self.underline(decorated) : decorated)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = label.alignment
            paragraph.lineBreakMode = .byWordWrapping  // the cell still truncates the last line
            aligned.addAttribute(
                .paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: aligned.length))
            label.attributedStringValue = aligned
        } else if underlined {
            label.attributedStringValue = NSAttributedString(
                string: name,
                attributes: [.font: font, .underlineStyle: NSUnderlineStyle.single.rawValue])
        } else {
            label.stringValue = name
        }
        // VoiceOver otherwise reads the attributed name's git letter + tag-dot glyphs; give it a
        // clean spoken description (name + kind/size/date) instead (A8).
        label.setAccessibilityLabel(accessibilityLabel ?? name)
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

    /// Add a single underline across an already-decorated name (for hover-to-open feedback).
    private static func underline(_ string: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        copy.addAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: copy.length))
        return copy
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil  // ignore any in-flight thumbnail for the previous file
    }

    override var isSelected: Bool { didSet { updateHighlight() } }

    private func updateHighlight() {
        view.layer?.cornerRadius = 6
        let selectedColor = ThemeManager.shared.customAccent ?? .selectedContentBackgroundColor
        view.layer?.backgroundColor = isSelected ? selectedColor.cgColor : NSColor.clear.cgColor
    }
}

/// Icon and gallery views, both NSCollectionView (gallery uses larger thumbnails).
/// Conforms to PaneContentView so PaneController can swap it for the list.
@MainActor
final class IconCollectionController: NSObject, NSCollectionViewDataSource,
    NSCollectionViewDelegate,
    NSTextFieldDelegate, PaneContentView
{
    let scrollView = NSScrollView()
    private let collection = KeyCollectionView()
    private let placeholder = NSTextField(labelWithString: "")
    private static let itemID = NSUserInterfaceItemIdentifier("icon-item")
    private static let headerID = NSUserInterfaceItemIdentifier("grid-header")

    private(set) var entries: [FileEntry] = []
    private let gallery: Bool
    private var scale: CGFloat = 1
    private var viewOptions = FolderViewOptions()
    func setViewOptions(_ options: FolderViewOptions) {
        guard viewOptions != options else { return }
        viewOptions = options
        scale = CGFloat(options.iconScale ?? 1)
        PaneAppearanceReload.collection(collection, in: scrollView) {
            if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = cellSize
                layout.minimumInteritemSpacing = CGFloat(options.gridSpacing ?? 8)
                layout.minimumLineSpacing = CGFloat(options.gridSpacing ?? 8)
                layout.invalidateLayout()
            }
        }
    }
    /// Harness accessors: the current zoom scale, and the key view that receives keyDown.
    var debugScale: CGFloat { scale }
    var debugKeyView: NSView { collection }
    private var baseIconSize: CGFloat { gallery ? 96 : 56 }
    private var iconSize: CGFloat { (baseIconSize * scale).rounded() }
    private var cellSize: NSSize {
        let side = iconSize
        if viewOptions.labelPosition == .right {
            return NSSize(width: side + 172, height: max(side + 8, labelFontSize * 2 + 12))
        }
        // Room for two full lines of the name under the icon: 4 pt above the icon, 4 pt between
        // icon and name, and the font's real line height (twice the point size is 2 to 4 pt
        // short, which cut the bottom off the second line).
        let lineHeight = NSLayoutManager().defaultLineHeight(
            for: .systemFont(ofSize: labelFontSize))
        let labelRoom = 8 + ceil(lineHeight * 2) + 2
        return gallery
            ? NSSize(width: side + 54, height: side + max(54, labelRoom))
            : NSSize(width: side + 40, height: side + max(36, labelRoom))
    }
    private var labelFontSize: CGFloat = 12
    /// Reports a new zoom scale so the pane can persist it across view switches/launches.
    var onZoomChanged: ((CGFloat) -> Void)?
    /// Shared tag-color + git-state cache, so grid items show the same decorations as the list.
    private let decorations = PaneDecorationCache()

    // MARK: - Grouping (Arrange By)
    //
    // When `grouping` is `.none` the grid is one flat section and an item's `indexPath.item` is its
    // entry index (unchanged). When grouping, entries are split into `sections` (a header title +
    // the entry indices under it), and every row<->entry touch point goes through the two mappings
    // below, so the flat path stays byte-for-byte identical.
    private var grouping: ViewFormat.GroupKey = .none
    private var sections: [(title: String, entryIndices: [Int])] = []
    private var isGrouped: Bool { grouping != .none && !sections.isEmpty }

    private func rebuildSections() {
        guard grouping != .none else {
            sections = []
            return
        }
        let rows = FileGrouping.rows(
            entries, by: grouping, now: Date(),
            tagColors: { [weak self] in
                guard let self, self.allowsLocalMetadata else { return [] }
                return self.decorations.tagColors(for: $0, in: self.directoryURL)
            })
        var built: [(title: String, entryIndices: [Int])] = []
        for row in rows {
            switch row {
            case .header(let title): built.append((title, []))
            case .item(let index):
                if !built.isEmpty { built[built.count - 1].entryIndices.append(index) }
            }
        }
        sections = built
    }

    /// The entry index a collection indexPath refers to, or nil if out of range.
    private func entryIndex(at indexPath: IndexPath) -> Int? {
        if isGrouped {
            guard indexPath.section < sections.count,
                indexPath.item < sections[indexPath.section].entryIndices.count
            else { return nil }
            return sections[indexPath.section].entryIndices[indexPath.item]
        }
        return indexPath.item < entries.count ? indexPath.item : nil
    }

    /// The collection indexPath showing entry `index`, or nil if it isn't currently displayed.
    private func indexPath(forEntry index: Int) -> IndexPath? {
        if isGrouped {
            for (section, group) in sections.enumerated() {
                if let item = group.entryIndices.firstIndex(of: index) {
                    return IndexPath(item: item, section: section)
                }
            }
            return nil
        }
        return index < entries.count ? IndexPath(item: index, section: 0) : nil
    }

    var supportsGrouping: Bool { true }

    func setGroupKey(_ key: ViewFormat.GroupKey) {
        guard key != grouping else { return }
        let selectedNames = Set(selectedEntries.map(\.name))
        grouping = key
        rebuildSections()
        updateHeaderLayout()
        collection.reloadData()
        selectNames(selectedNames)
    }

    /// Smoke: group by kind, confirm the sections cover every entry and a selection round-trips
    /// through the section<->entry mapping, then return to flat.
    func debugGroupRoundTrips() -> Bool {
        guard let first = entries.first else { return true }
        setGroupKey(.kind)
        let grouped = isGrouped
        let coversAll = sections.reduce(0) { $0 + $1.entryIndices.count } == entries.count
        select(name: first.name)
        let mapped = selectedEntries.count == 1 && selectedEntries.first?.name == first.name
        setGroupKey(.none)
        return grouped && coversAll && mapped && !isGrouped
    }

    var directoryURL: URL?
    var resolutionURL: URL?
    var allowsLocalMetadata = true {
        didSet {
            guard allowsLocalMetadata != oldValue else { return }
            if !allowsLocalMetadata {
                decorations.refreshTags(entries: [], directory: nil)
                decorations.setGitStates([:])
                // Reconfigure reused items with nil thumbnail URLs, so a late local thumbnail
                // cannot replace a remote item's generic icon after this context switch.
                collection.reloadData()
            }
            // Re-enabling waits for setEntries: the old rows can still belong to a remote host.
        }
    }
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?  // grid has no column headers
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    /// The committed name of an in-place rename (Finder-style edit in the grid).
    var onInlineRename: ((FileEntry, String) -> Void)?
    /// The entry being renamed in place (nil = not editing); guards commit against reuse/reload.
    private var editingEntry: FileEntry?
    var isInlineEditing: Bool { editingEntry != nil }
    /// Esc pressed during an edit: abandon without committing.
    private var renameCancelled = false

    var keyView: NSView { collection }
    /// Smoke guard: true iff the grid forwards its focus to the pane (so selecting an icon/gallery
    /// pane makes it active). Was silently false before, unlike list/column/tree.
    var debugForwardsFocusToPane: Bool { collection.onBecomeActive != nil }
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
        decorations.onTagsChanged = { [weak self] in self?.tagsDidChange() }
        collection.onHover = { [weak self] indexPath in
            self?.setHovered(indexPath.flatMap { self?.entryIndex(at: $0) } ?? -1)
        }
        collection.onSuperDrag = { [weak self] event in self?.onDragSession?(event) }
        collection.onDragExited = { [weak self] in self?.springLoader.cancel() }
        // Clicking the grid makes it first responder; forward that so the pane becomes active and
        // takes focus (as list/column/tree do). Without this, selecting an icon/gallery pane left
        // the active pane -- and keyboard focus -- on the previously active one.
        collection.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.collection.reloadData() }
    }

    /// Right-drag flick + swipe trail (super-drag), forwarded from the collection view.
    var onDragSession: ((DragSessionEvent) -> Void)?

    /// Which entry the pointer is over (-1 = none), underlined when hover-to-open is on.
    private var hoveredItem = -1

    private func setHovered(_ entryIndex: Int) {
        guard entryIndex != hoveredItem else { return }
        let old = hoveredItem
        hoveredItem = entryIndex
        var paths = Set<IndexPath>()
        if old >= 0, let path = indexPath(forEntry: old) { paths.insert(path) }
        if entryIndex >= 0, let path = indexPath(forEntry: entryIndex) { paths.insert(path) }
        if !paths.isEmpty { collection.reloadItems(at: paths) }
    }

    /// When grouping by tag, the newly-read tags change the buckets, so rebuild the sections
    /// (preserving selection); otherwise just redraw the dots.
    private func tagsDidChange() {
        if grouping == .tag {
            let names = Set(selectedEntries.map(\.name))
            rebuildSections()
            updateHeaderLayout()
            collection.reloadData()
            selectNames(names)
        } else {
            collection.reloadData()
        }
    }

    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        collection.singleClickToOpen = singleClick
        collection.setHoverTracking(underlineHover)
        if !underlineHover { setHovered(-1) }
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

    /// Give the flow layout room for section headers when grouping, none otherwise.
    private func updateHeaderLayout() {
        guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else {
            return
        }
        layout.headerReferenceSize = isGrouped ? NSSize(width: 0, height: 26) : .zero
        layout.invalidateLayout()
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
        collection.register(
            GridHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: Self.headerID)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask(.every, forLocal: false)  // effectAllowed="all", like Finder
        collection.onActivate = { [weak self] indexPath in
            guard let self else { return }
            if let indexPath, let ei = self.entryIndex(at: indexPath) {
                self.onOpen?(self.entries[ei])  // the double-clicked item
            } else if let first = self.selectedEntries.first {
                self.onOpen?(first)  // Return with a selection
            }
        }
        collection.onSelectionMutated = { [weak self] in self?.onSelectionChanged?() }
        contextMenu.selectedURLs = { [weak self] in self?.contextSelectionURLs() ?? [] }
        contextMenu.currentFolder = { [weak self] in
            guard let self, self.allowsLocalMetadata else { return nil }
            return self.directoryURL
        }
        collection.menu = contextMenu.menu

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
            placeholder.widthAnchor.constraint(
                lessThanOrEqualTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    /// The one shared file context menu, identical across every pane view (list, icon,
    /// gallery, column) so the icon view gets Open With, Tags, and Extract for free and can
    /// never drift from the others. Honors the Settings ▸ Menus hide/show choice.
    private let contextMenu = FileContextMenuController()
    func setHiddenContextItems(_ ids: Set<String>) { contextMenu.hiddenItems = ids }
    func setContextMenuOrder(_ order: [String]) { contextMenu.menuOrder = order }
    private var colorRules = ColorRules()
    func setColorRules(_ rules: ColorRules) {
        guard rules != colorRules else { return }
        PaneAppearanceReload.collection(collection, in: scrollView) { colorRules = rules }
    }

    var selectedEntries: [FileEntry] {
        collection.selectionIndexPaths.compactMap { entryIndex(at: $0).map { entries[$0] } }
    }

    /// The selection as file URLs, for the shared menu's archive gating and Open With.
    private func contextSelectionURLs() -> [URL] {
        guard allowsLocalMetadata else { return [] }
        let base = directoryURL
        return selectedEntries.compactMap { entry in
            if let location = entry.location {
                return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
            }
            return base?.appendingPathComponent(entry.name)
        }
    }

    // MARK: - Cut dimming + selection anchor (parity with the list view)

    /// Paths currently marked for cut, dimmed until pasted or the cut is cleared.
    private var cutPaths: Set<String> = []
    private func isCut(_ entry: FileEntry) -> Bool {
        allowsLocalMetadata && !cutPaths.isEmpty
            && cutPaths.contains(PaneItemKey.path(for: entry, in: directoryURL))
    }
    /// Cut items dim most, then hidden (dotfile) items; everything else is opaque.
    private func alpha(for entry: FileEntry) -> CGFloat {
        isCut(entry) ? 0.45 : (entry.isHidden ? 0.5 : 1.0)
    }

    func setCutPaths(_ paths: Set<String>) {
        guard paths != cutPaths else { return }
        let changed = paths.symmetricDifference(cutPaths)  // only these items change appearance
        cutPaths = paths
        // Re-dim just the items whose cut state flipped; leave selection and scroll untouched.
        // Off-screen items pick up the right alpha when they are next configured.
        for (i, entry) in entries.enumerated()
        where changed.contains(PaneItemKey.path(for: entry, in: directoryURL)) {
            if let path = indexPath(forEntry: i) {
                (collection.item(at: path) as? IconItem)?.view.alphaValue = alpha(for: entry)
            }
        }
    }

    /// The selection's bounding rect in window coordinates so the quick-actions bar hugs the
    /// selected icons instead of centering on the pane.
    func selectionRectInWindow() -> NSRect? {
        let paths = collection.selectionIndexPaths
        guard !paths.isEmpty else { return nil }
        var union = NSRect.null
        for path in paths {
            if let attrs = collection.layoutAttributesForItem(at: path) {
                union = union.union(attrs.frame)
            }
        }
        guard !union.isNull else { return nil }
        let visible = union.intersection(collection.visibleRect)
        guard !visible.isNull, visible.height > 1 else { return nil }  // scrolled out of view
        return collection.convert(visible, to: nil)
    }

    func setEntries(_ entries: [FileEntry], preserveState: Bool) {
        cancelInlineEdit()  // a background reload must not commit a half-typed rename
        let selectedNames = preserveState ? Set(selectedEntries.map(\.name)) : []
        self.entries = entries
        rebuildSections()
        updateHeaderLayout()
        collection.reloadData()
        if !selectedNames.isEmpty { selectNames(selectedNames) }
        // Read tag colors off-main, then redraw once if any item shows a dot (untagged is free).
        decorations.refreshTags(
            entries: allowsLocalMetadata ? entries : [],
            directory: allowsLocalMetadata ? directoryURL : nil)
    }

    /// Repro/instrument for "content pushes up when I select an item in a small folder" (#5):
    /// list `entries` in a single column at a bounded height, then select an item that is already
    /// fully on screen. Revealing an already-visible item must not scroll at all -- a non-zero
    /// result is the `.centeredVertically` nudge (it re-centered the item, yanking the top rows out
    /// of view). Returns the absolute vertical scroll caused by the selection.
    func debugSelectNudge(
        listing entries: [FileEntry], in dir: URL, height: CGFloat, selectIndex: Int
    ) -> CGFloat {
        directoryURL = dir
        setEntries(entries, preserveState: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: 170, height: height)  // narrow -> one item per row
        scrollView.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        // A no-nudge control must really be fully visible, not merely intersect the clip.
        guard entries.indices.contains(selectIndex),
            let path = indexPath(forEntry: selectIndex),
            let frame = collection.layoutAttributesForItem(at: path)?.frame,
            collection.visibleRect.contains(frame)
        else { return .infinity }
        let before = scrollView.contentView.bounds.origin.y
        if entries.indices.contains(selectIndex) { select(name: entries[selectIndex].name) }
        scrollView.layoutSubtreeIfNeeded()
        return abs(scrollView.contentView.bounds.origin.y - before)
    }

    func setGitStates(_ states: [String: GitFileState]) {
        if decorations.setGitStates(allowsLocalMetadata ? states : [:]) { collection.reloadData() }
    }

    func invalidateTagCache() { decorations.invalidateTags() }

    func setBackgroundColor(_ color: NSColor?) {
        // The collection stays clear, so the scroll view's background (or, when transparent, the
        // folder background image behind the pane) shows through the grid.
        let transparent = (color?.alphaComponent ?? 1) < 0.02
        scrollView.backgroundColor = transparent ? .clear : (color ?? .controlBackgroundColor)
        scrollView.drawsBackground = !transparent
    }

    func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    func select(name: String) {
        guard let index = entries.firstIndex(where: { $0.name == name }),
            let path = indexPath(forEntry: index)
        else { return }
        collection.selectionIndexPaths = [path]
        // Reveal minimally (nearest edge), never re-center: centering an item that's already on
        // screen yanked the content up in small folders (#5). No-op when the item is fully visible.
        // On the current AppKit, nearestVerticalEdge can leave the clip at y=0 even
        // with a valid offscreen item frame (real-window layout regression). Use the
        // view's minimal rect reveal, after resolving the current flow layout.
        collection.layoutSubtreeIfNeeded()
        if let frame = collection.layoutAttributesForItem(at: path)?.frame,
            !collection.visibleRect.contains(frame)
        {
            collection.scrollToVisible(frame)
        }
    }

    func selectNames(_ names: Set<String>) {
        var paths = Set<IndexPath>()
        for (index, entry) in entries.enumerated() where names.contains(entry.name) {
            if let path = indexPath(forEntry: index) { paths.insert(path) }
        }
        collection.selectionIndexPaths = paths
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}  // no headers in a grid

    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        PaneAppearanceReload.collection(collection, in: scrollView) { labelFontSize = fontSize }
    }

    // MARK: In-place rename (Finder-style, so a new folder is named right in the grid)

    /// Begin editing the single selected item's name inline. Returns false when it can't (nothing or
    /// many selected, or the cell isn't realized), so the pane falls back to the rename sheet.
    func beginInlineRename() -> Bool {
        guard editingEntry == nil else { return false }
        let selected = selectedEntries
        guard selected.count == 1, let entry = selected.first,
            let index = entries.firstIndex(where: { $0.name == entry.name }),
            let path = indexPath(forEntry: index)
        else { return false }
        // Make sure the cell exists and is on screen before grabbing its label (nearest edge, so an
        // already-visible item to rename doesn't jump the view; #5).
        collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        collection.layoutSubtreeIfNeeded()
        guard let field = (collection.item(at: path) as? IconItem)?.textField else { return false }
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
        collection.window?.makeFirstResponder(field)
        // Select the base name only (exclude the extension), the way Finder does.
        if let editor = field.currentEditor() {
            let ns = entry.name as NSString
            let ext = ns.pathExtension as NSString
            let baseLength =
                (!entry.isDirectory && ext.length > 0) ? ns.length - ext.length - 1 : ns.length
            editor.selectedRange = NSRange(location: 0, length: max(0, baseLength))
        }
        return true
    }

    /// Restore an edited name label to its plain, non-editable appearance.
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
            let path = indexPath(forEntry: index),
            let field = (collection.item(at: path) as? IconItem)?.textField
        {
            endInlineEditing(field)
            if field.currentEditor() != nil { collection.window?.makeFirstResponder(collection) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        if selector == #selector(NSResponder.cancelOperation(_:)) {  // Esc abandons the edit
            renameCancelled = true
            collection.window?.makeFirstResponder(collection)
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
        // Repaint the item so the stripped tag/git decoration returns; a successful rename also
        // triggers a full re-list from the pane.
        if let index = entries.firstIndex(where: { $0.name == entry.name }),
            let path = indexPath(forEntry: index)
        {
            collection.reloadItems(at: [path])
        }
        guard !cancelled, !newName.isEmpty, newName != entry.name else { return }
        onInlineRename?(entry, newName)
    }

    // MARK: NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        isGrouped ? sections.count : 1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
        -> Int
    {
        isGrouped ? sections[section].entryIndices.count : entries.count
    }

    /// A section-header supplementary view showing the group title (only when grouping).
    func collectionView(
        _ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> NSView {
        let view =
            collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: Self.headerID, for: indexPath) as! GridHeaderView
        view.title = indexPath.section < sections.count ? sections[indexPath.section].title : ""
        return view
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    )
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! IconItem
        guard let ei = entryIndex(at: indexPath) else { return item }
        let entry = entries[ei]
        let base = entry.isDataless ? Self.cloudIcon : Self.icon(for: entry)
        let image =
            allowsLocalMetadata
            ? CloudBadge.decorate(
                base, for: entry, in: directoryURL, size: NSSize(width: iconSize, height: iconSize))
            : base
        // Real content thumbnails for files only; never for folders or online-only
        // (dataless) items, where generating one could fault a download.
        let thumbnailURL =
            (entry.isDirectory || entry.isDataless || viewOptions.showIconPreviews == false)
            ? nil : fileURL(for: entry)
        let ruleStyle = FileColorStyle.style(
            for: entry, rules: colorRules, baseFont: .systemFont(ofSize: labelFontSize))
        item.configure(
            name: entry.name, image: image, iconSize: iconSize, fontSize: labelFontSize,
            dimmed: entry.isDataless, thumbnailURL: thumbnailURL,
            git: allowsLocalMetadata ? decorations.gitState(for: entry, in: directoryURL) : nil,
            tags: allowsLocalMetadata ? decorations.tagColors(for: entry, in: directoryURL) : [],
            underlined: ei == hoveredItem, nameFont: ruleStyle?.font, nameColor: ruleStyle?.color,
            accessibilityLabel: FileAXLabel.describe(entry),
            labelPosition: viewOptions.labelPosition ?? .below)
        // Dim hidden (dotfile) items so they read as hidden when "show hidden files" is on,
        // as Finder does, and dim cut items until pasted. Set on every configure (cells are
        // reused) so it never sticks.
        item.view.alphaValue = alpha(for: entry)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        onSelectionChanged?()
    }

    func collectionView(
        _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        onSelectionChanged?()
    }

    // MARK: Drag and drop

    func collectionView(
        _ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath
    )
        -> NSPasteboardWriting?
    {
        guard let dir = directoryURL, let ei = entryIndex(at: indexPath) else { return nil }
        let entry = entries[ei]
        guard !entry.isDataless else { return nil }
        return FileDrag.item(for: dir.appendingPathComponent(entry.name))  // promise + file URL
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let dir = directoryURL else { return }
        let urls = indexPaths.compactMap { path -> URL? in
            guard let ei = entryIndex(at: path), !entries[ei].isDataless else { return nil }
            return dir.appendingPathComponent(entries[ei].name)
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
        if let path = folderIndexPath(under: draggingInfo, in: collectionView, excluding: urls),
            let ei = entryIndex(at: path)
        {
            proposedDropOperation.pointee = .on
            proposedIndexPath.pointee = path as NSIndexPath
            let entry = entries[ei]  // dwell here to spring the folder open
            if let folder = fileURL(for: entry) {
                springLoader.arm(key: folder.path) { [weak self] in self?.onOpen?(entry) }
            }
        } else {
            springLoader.cancel()
            guard !incomingURLs(urls, into: directoryURL).isEmpty else { return [] }
            proposedDropOperation.pointee = .before
            // A valid "append to the end" target in the last section (works grouped or flat).
            let lastSection = max(0, (isGrouped ? sections.count : 1) - 1)
            let itemsInLast = isGrouped ? (sections.last?.entryIndices.count ?? 0) : entries.count
            proposedIndexPath.pointee = NSIndexPath(forItem: itemsInLast, inSection: lastSection)
        }
        return resolvedDragOperation(draggingInfo)
    }

    /// Spring-loaded folders: dwelling a drag over a folder item opens it (via onOpen).
    private let springLoader = SpringLoader()

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        springLoader.cancel()  // the drop resolved; don't spring afterward
        guard let urls = draggedURLs(from: draggingInfo), !urls.isEmpty else { return false }
        guard !resolvedDragOperation(draggingInfo).isEmpty else { return false }
        var folder: URL?
        if dropOperation == .on, let ei = entryIndex(at: indexPath), entries[ei].isDirectory {
            folder = fileURL(for: entries[ei])
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
        guard let path = collectionView.indexPathForItem(at: point), let ei = entryIndex(at: path),
            entries[ei].isDirectory, let folder = fileURL(for: entries[ei])
        else { return nil }
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if dragged.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == folderPath
        }) {
            return nil  // don't drop a folder onto itself
        }
        return path
    }

    /// The on-disk URL of an entry (smart-result rows carry their own folder).
    private func fileURL(for entry: FileEntry) -> URL? {
        guard allowsLocalMetadata else { return nil }
        if let location = entry.location {
            return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
        }
        return directoryURL?.appendingPathComponent(entry.name)
    }

    private func draggedURLs(from info: NSDraggingInfo) -> [URL]? {
        FileDrag.readFileURLs(from: info.draggingPasteboard)
    }

    private func incomingURLs(_ urls: [URL], into destination: URL?) -> [URL] {
        guard let destination else { return [] }
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                .compare(destPath, options: .caseInsensitive) != .orderedSame
        }
    }

    /// Move dragged items between folders by default (else copy); Command inverts it, matching
    /// the list. Driven by the pref via PaneController.
    var dragMovesByDefault = Preferences.default.dragMovesByDefault

    private func resolvedDragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        FileDrag.operation(for: info, movesByDefault: dragMovesByDefault)
    }

    // MARK: Icons

    private static let cloudIcon =
        NSImage(
            systemSymbolName: "icloud.and.arrow.down",
            accessibilityDescription: L("icons.onlineOnly", "Online only")) ?? NSImage()
    private static var iconCache: [String: NSImage] = [:]

    private static func icon(for entry: FileEntry) -> NSImage {
        if let themed = IconSetManager.shared.icon(for: entry) { return themed }  // active icon set
        let key =
            entry.isDirectory ? "\u{0}folder" : (entry.name as NSString).pathExtension.lowercased()
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

/// A section-header supplementary view for the grouped icon grid: the group title, styled to match
/// the list view's group headers.
final class GridHeaderView: NSView, NSCollectionViewElement {
    var title: String = "" { didSet { label.stringValue = title } }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
