import AppKit

/// A custom breadcrumb (replacing NSPathControl) so each ancestor segment is an exact drop
/// target: dropping files onto a segment moves/copies them into that ancestor folder. Each
/// segment is also a drag source (drag a folder out to the Dock / VS Code / Terminal) and
/// navigates on click. NSPathControl can't do per-segment file drops, and estimating segment
/// frames risks dropping into the wrong folder, so this is a from-scratch control.
@MainActor
final class BreadcrumbBar: NSView {
    var onNavigate: ((URL) -> Void)?
    var onDropURLs: ((_ urls: [URL], _ folder: URL, _ move: Bool) -> Void)?
    /// A click on the bar's empty area (not a segment) opens the editable path field.
    var onClickBackground: (() -> Void)?

    private let stack = NSStackView()
    private var current: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)  // hug the segment height, don't stretch
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onClickBackground?() }

    func setURL(_ url: URL?) {
        guard current != url else { return }
        current = url
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        for (index, folder) in Self.ancestors(of: url).enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.font = .systemFont(ofSize: 12)
                separator.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(separator)
            }
            let segment = BreadcrumbSegment(folder: folder)
            segment.title = FileManager.default.displayName(atPath: folder.path)
            segment.onClick = { [weak self] in self?.onNavigate?(folder) }
            segment.onDropURLs = { [weak self] urls, move in self?.onDropURLs?(urls, folder, move) }
            stack.addArrangedSubview(segment)
        }
    }

    /// Root .. current, as folder URLs.
    static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var folder = url.standardizedFileURL
        while true {
            result.insert(folder, at: 0)
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }  // reached "/"
            folder = parent
        }
        return result
    }
}

/// One breadcrumb segment: click to navigate, drag out to other apps, accept file drops.
@MainActor
final class BreadcrumbSegment: NSButton, NSDraggingSource {
    let folder: URL
    var onClick: (() -> Void)?
    var onDropURLs: ((_ urls: [URL], _ move: Bool) -> Void)?
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

    // Click vs drag: track the mouse; a small move starts a drag-out, otherwise it's a click.
    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        var dragged = false
        trackingLoop: while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseUp: break trackingLoop
            case .leftMouseDragged:
                let point = next.locationInWindow
                if abs(point.x - start.x) > 4 || abs(point.y - start.y) > 4 {
                    dragged = true
                    beginDrag(with: next)
                    break trackingLoop
                }
            default: break
            }
        }
        if !dragged { onClick?() }
    }

    private func beginDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: folder as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : [.copy, .move]
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDropTarget = false }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let urls = urls(from: info), !urls.isEmpty, !isSelfOrParentOnly(urls) else {
            isDropTarget = false
            return []
        }
        isDropTarget = true
        return NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .move : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let urls = urls(from: sender), !urls.isEmpty, !isSelfOrParentOnly(urls) else { return false }
        onDropURLs?(urls, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
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
            let parent = $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            return item == here || parent.compare(here, options: .caseInsensitive) == .orderedSame
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}
