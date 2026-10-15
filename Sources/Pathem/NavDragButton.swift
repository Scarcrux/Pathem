import AppKit

/// A toolbar navigation button (Back / Forward / Enclosing Folder) that also participates in a
/// file drag, like Finder's path controls: hovering a drag over it navigates after the
/// spring-loading delay, and dropping files on the Up button moves/copies them into the enclosing
/// folder. Back/Forward spring-load only (no single drop destination). Plain click still works.
@MainActor
final class NavDragButton: NSButton {
    var dragMovesByDefault = true
    /// The folder a drop lands in, evaluated live (nil = not a drop target, e.g. Back/Forward).
    var dropDestination: (() -> URL?)?
    var onDropURLs: ((_ urls: [URL], _ move: Bool, _ destination: URL) -> Void)?
    /// Navigate when a drag rests here long enough (spring-load): Up / Back / Forward.
    var onSpringLoad: (() -> Void)?

    private var springLoad: DispatchWorkItem?
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            contentTintColor = isDropTarget ? .controlAccentColor : nil  // tint the chevron while a valid drop hovers
        }
    }

    /// Turn on file-drag participation (drop + spring-load). Call after wiring the closures.
    func enableDragNavigation() { registerForDraggedTypes([.fileURL]) }

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
    // @objc so AppKit finds the optional draggingEnded: on NSView; without it a completed drag can
    // raise "unrecognized selector" and strand later drags. No super.
    @objc override func draggingEnded(_ sender: NSDraggingInfo) {
        cancelSpringLoad()
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cancelSpringLoad()  // a drop shouldn't also spring-navigate
        isDropTarget = false
        guard let destination = dropDestination?(), let urls = fileURLs(sender), !urls.isEmpty,
            !allAlreadyInside(urls, destination)
        else { return false }
        let operation = FileDrag.operation(for: sender, movesByDefault: dragMovesByDefault)
        guard !operation.isEmpty else { return false }
        onDropURLs?(urls, operation == .move, destination)
        return true
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let destination = dropDestination?(), let urls = fileURLs(info), !urls.isEmpty,
            !allAlreadyInside(urls, destination)
        else {
            isDropTarget = false
            return []
        }
        isDropTarget = true
        return FileDrag.operation(for: info, movesByDefault: dragMovesByDefault)
    }

    /// Arm the spring-load once, when a file drag first rests on the button; uses the system
    /// spring-loading delay so it matches Finder / the user's "Spring-loaded folders" setting.
    private func armSpringLoad(_ info: NSDraggingInfo) {
        guard springLoad == nil, onSpringLoad != nil, fileURLs(info)?.isEmpty == false else {
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.onSpringLoad?() }
        springLoad = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval + 0.35, execute: work)
    }
    private func cancelSpringLoad() {
        springLoad?.cancel()
        springLoad = nil
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    /// Reject a drop when every item is already directly inside `destination` (moving there is a
    /// no-op), matching the breadcrumb's guard.
    private func allAlreadyInside(_ urls: [URL], _ destination: URL) -> Bool {
        let dest = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.allSatisfy {
            $0.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path
                == dest
        }
    }
}
