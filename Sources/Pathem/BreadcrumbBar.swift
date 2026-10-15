import AppKit

/// A custom breadcrumb (replacing NSPathControl) so each ancestor segment is an exact drop
/// target: dropping files onto a segment moves/copies them into that ancestor folder. Each
/// segment is also a drag source (drag a folder out to the Dock / VS Code / Terminal) and
/// navigates on click. NSPathControl can't do per-segment file drops, and estimating segment
/// frames risks dropping into the wrong folder, so this is a from-scratch control.
@MainActor
final class BreadcrumbBar: NSView {
    var dragMovesByDefault = true {
        didSet {
            for case let segment as BreadcrumbSegment in stack.arrangedSubviews {
                segment.dragMovesByDefault = dragMovesByDefault
            }
        }
    }
    var onNavigate: ((URL) -> Void)?
    var onDropURLs: ((_ urls: [URL], _ folder: URL, _ move: Bool) -> Void)?
    /// A click on the bar's empty area (not a segment) opens the editable path field.
    var onClickBackground: (() -> Void)?
    /// A right-click action on a path segment (open it into a pane / tab, or copy its path).
    var onContextAction: ((URL, Action) -> Void)?

    /// What a breadcrumb segment's context menu can do with that ancestor folder.
    enum Action {
        case newTab, leftPane, rightPane, leftPaneNewTab, rightPaneNewTab, copyPath
    }

    private let stack = NSStackView()
    private var current: URL?

    /// In demo mode, breadcrumbs show the path from this fake root (labeled "Home"), hiding the
    /// real temp-directory prefix so screenshots look clean.
    static var demoRoot: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // A fixed-height row. Without this the bar has no intrinsic height, so it stretches to
        // fill whatever vertical space the content view yields (a gallery yields a lot), which
        // pushed the content down. The stack centers its segments within the row.
        let height = heightAnchor.constraint(equalToConstant: 26)
        height.priority = .required
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            height,
        ])
        setContentHuggingPriority(.init(1), for: .horizontal)
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onClickBackground?() }

    func setURL(_ url: URL?) {
        guard current != url else { return }
        current = url
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        var ancestors = Self.ancestors(of: url)
        // Demo mode: drop everything above the fake root and label the root "Home".
        var rootLabel: String?
        if let demoRoot = Self.demoRoot?.standardizedFileURL,
            let rootIndex = ancestors.firstIndex(where: { $0.standardizedFileURL == demoRoot })
        {
            ancestors = Array(ancestors[rootIndex...])
            rootLabel = L("breadcrumb.home", "Home")
        }
        for (index, folder) in ancestors.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.font = .systemFont(ofSize: 12)
                separator.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(separator)
            }
            let segment = BreadcrumbSegment(folder: folder)
            segment.dragMovesByDefault = dragMovesByDefault
            segment.title =
                index == 0 && rootLabel != nil
                ? rootLabel! : FileManager.default.displayName(atPath: folder.path)
            segment.onClick = { [weak self] in self?.onNavigate?(folder) }
            segment.onSpringLoad = { [weak self] in self?.onNavigate?(folder) }
            segment.onDropURLs = { [weak self] urls, move in self?.onDropURLs?(urls, folder, move) }
            segment.onContextAction = { [weak self] action in self?.onContextAction?(folder, action)
            }
            stack.addArrangedSubview(segment)
        }
    }

    /// Root .. current, as folder URLs.
    static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var folder = url.standardizedFileURL
        while true {
            result.insert(folder, at: 0)
            if folder.path == "/" { break }  // reached root; stop before "/" -> "/.." loops
            // Standardize the parent: for a directory URL (trailing slash), deletingLastPathComponent
            // can yield "/../" chains that never equal their child, so normalize and guard on length.
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            guard parent.path != folder.path, parent.path.count < folder.path.count else { break }
            folder = parent
        }
        return result
    }
}

/// One breadcrumb segment: click to navigate, drag out to other apps, accept file drops.
@MainActor
final class BreadcrumbSegment: NSButton, NSDraggingSource {
    var dragMovesByDefault = true
    let folder: URL
    var onClick: (() -> Void)?
    var onDropURLs: ((_ urls: [URL], _ move: Bool) -> Void)?
    /// Fired when a drag hovers this segment long enough to "spring-load" it: navigate to this
    /// ancestor mid-drag so you can drop into what it reveals, the way Finder drills in when you
    /// hold a drag over a path component.
    var onSpringLoad: (() -> Void)?
    var onContextAction: ((BreadcrumbBar.Action) -> Void)?

    /// Pending spring-load, armed while a drag rests on this segment and cancelled the moment it
    /// leaves (or drops), so a drag merely passing over doesn't navigate.
    private var springLoad: DispatchWorkItem?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: BreadcrumbBar.Action) {
            let item = menu.addItem(
                withTitle: title, action: #selector(contextSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
        }
        add(L("crumb.newTab", "Open in New Tab"), .newTab)
        menu.addItem(.separator())
        add(L("crumb.leftPane", "Open in Left Pane"), .leftPane)
        add(L("crumb.rightPane", "Open in Right Pane"), .rightPane)
        add(L("crumb.leftPaneNewTab", "Open in Left Pane (New Tab)"), .leftPaneNewTab)
        add(L("crumb.rightPaneNewTab", "Open in Right Pane (New Tab)"), .rightPaneNewTab)
        menu.addItem(.separator())
        add(L("crumb.copyPath", "Copy Path"), .copyPath)
        return menu
    }

    @objc private func contextSelected(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? BreadcrumbBar.Action else { return }
        onContextAction?(action)
    }
    private var isDropTarget = false { didSet { needsDisplay = true } }

    init(folder: URL) {
        self.folder = folder
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        font = .systemFont(ofSize: 12)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        lineBreakMode = .byTruncatingMiddle
        if let buttonCell = cell as? NSButtonCell {
            buttonCell.wraps = false  // single line; don't stack the title vertically
            buttonCell.lineBreakMode = .byTruncatingMiddle
        }
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Click vs drag via the standard responder overrides, not a hand-rolled nextEvent pump.
    // Pumping the queue raced quick flicks (start a drag session as the mouse-up is already
    // queued), which can strand an orphaned NSDraggingSession and silently kill every later
    // drag in the process until relaunch. mouseDragged only fires while the button is down,
    // so a session can never start after release.
    private var pressStart: NSPoint?
    private var didStartDrag = false

    override func mouseDown(with event: NSEvent) {
        // No super: the button's own tracking loop would swallow mouseDragged/mouseUp.
        pressStart = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart, !didStartDrag else { return }
        let point = event.locationInWindow
        if abs(point.x - start.x) > 6 || abs(point.y - start.y) > 6 {
            didStartDrag = true
            beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if pressStart != nil, !didStartDrag { onClick?() }
        pressStart = nil
        didStartDrag = false
    }

    private func beginDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: FileDrag.item(for: folder))
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .every : [.copy, .move]  // "all" outside, like Finder
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint)
    {
        FileDrag.addLegacyFilenames([folder], to: session.draggingPasteboard)  // legacy apps read this
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        armSpringLoad(sender)
        return dropOperation(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        cancelSpringLoad()
        isDropTarget = false
    }
    // @objc so the optional draggingEnded: is actually exposed to ObjC (NSView doesn't implement it);
    // without it AppKit's drag completion raises "unrecognized selector" and strands drags. No super.
    @objc override func draggingEnded(_ sender: NSDraggingInfo) {
        cancelSpringLoad()
        isDropTarget = false
    }

    /// Arm the spring-load once, when a file drag first rests on the segment. Uses the system
    /// spring-loading delay so it matches Finder / the user's "Spring-loaded folders" setting.
    private func armSpringLoad(_ info: NSDraggingInfo) {
        guard springLoad == nil, let urls = urls(from: info), !urls.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.onSpringLoad?() }
        springLoad = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval + 0.35, execute: work)
    }
    private func cancelSpringLoad() {
        springLoad?.cancel()
        springLoad = nil
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let urls = urls(from: info), !urls.isEmpty, !isSelfOrParentOnly(urls) else {
            isDropTarget = false
            return []
        }
        isDropTarget = true
        return FileDrag.operation(for: info, movesByDefault: dragMovesByDefault)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cancelSpringLoad()  // a drop here shouldn't also spring-navigate
        isDropTarget = false
        guard let urls = urls(from: sender), !urls.isEmpty, !isSelfOrParentOnly(urls) else {
            return false
        }
        let operation = FileDrag.operation(for: sender, movesByDefault: dragMovesByDefault)
        guard !operation.isEmpty else { return false }
        onDropURLs?(urls, operation == .move)
        return true
    }

    private func urls(from info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    /// Reject if every dragged item is already directly inside this folder, or is this folder.
    private func isSelfOrParentOnly(_ urls: [URL]) -> Bool {
        let here = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.allSatisfy {
            let item = $0.resolvingSymlinksInPath().standardizedFileURL.path
            let parent = $0.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL.path
            return item == here || parent.compare(here, options: .caseInsensitive) == .orderedSame
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            ThemeManager.shared.accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}
