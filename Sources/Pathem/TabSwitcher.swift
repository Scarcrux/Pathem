import AppKit
import PathemEngine

/// One row of the tab switcher.
struct TabSwitcherEntry {
    let id: ObjectIdentifier
    let sideLabel: String  // "L" or "R"
    let title: String
    let path: String
    let locked: Bool
}

/// The Ctrl-Tab overlay: a small themed panel listing the tabs of both panes, most recently
/// used first. Holding Ctrl and pressing Tab cycles, releasing Ctrl picks. Esc cancels.
/// Keyboard first: while it is up a local event monitor consumes every key.
@MainActor
final class TabSwitcherController {
    private(set) var selection: TabSwitcherSelection<ObjectIdentifier>?
    private var entries: [TabSwitcherEntry] = []
    private var panel: NSPanel?
    private var rows: [NSView] = []
    private var monitor: Any?
    private var showWork: DispatchWorkItem?
    /// Called with the picked tab when the switcher closes by selection.
    var onCommit: ((ObjectIdentifier) -> Void)?
    /// Whether Ctrl was down when the switcher opened (it commits on release); without it
    /// (palette, menu) the panel stays up until Return, a click, or Esc.
    private var releaseCommits = true

    var isOpen: Bool { selection != nil }

    /// Open (or, when already open, advance) the switcher. The panel itself appears after a
    /// short beat so a quick Ctrl-Tab tap just flips to the previous tab without a flash.
    func open(
        entries: [TabSwitcherEntry], reverse: Bool, over window: NSWindow?,
        immediately: Bool = false
    ) {
        if isOpen {
            selection?.advance(reverse: reverse)
            refreshRows()
            return
        }
        guard let start = TabSwitcherSelection(order: entries.map(\.id), reverse: reverse)
        else { return }
        self.entries = entries
        selection = start
        releaseCommits = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(
            .control)
        installMonitor()
        let present = { [weak self] in
            guard let self, self.isOpen, let window else { return }
            self.buildPanel(over: window)
        }
        if immediately || !releaseCommits {
            present()
        } else {
            let work = DispatchWorkItem(block: present)
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    func cancel() { close(commit: false) }

    private func close(commit: Bool) {
        guard let chosen = selection?.chosen else { return }
        showWork?.cancel()
        showWork = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        panel = nil
        rows = []
        selection = nil
        if commit { onCommit?(chosen) }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged, .leftMouseDown,
        ]) {
            [weak self] event in
            guard let self, self.isOpen else { return event }
            switch event.type {
            case .flagsChanged:
                if self.releaseCommits, !event.modifierFlags.contains(.control) {
                    self.close(commit: true)
                }
                return event
            case .leftMouseDown:
                self.close(commit: false)
                return nil
            default:
                self.handleKey(event)
                return nil  // every key is swallowed while open
            }
        }
    }

    /// Returns true (always: the switcher owns the keyboard while open).
    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 48:  // tab
            selection?.advance(reverse: shift)
            refreshRows()
        case 126, 123:  // up, left
            selection?.advance(reverse: true)
            refreshRows()
        case 125, 124:  // down, right
            selection?.advance(reverse: false)
            refreshRows()
        case 36, 76:  // return
            close(commit: true)
        case 53:  // escape
            close(commit: false)
        default: break
        }
        return true
    }

    // MARK: - Panel

    private func buildPanel(over window: NSWindow) {
        let width: CGFloat = 460
        let rowHeight: CGFloat = 40
        let visible = min(entries.count, 10)
        let height = CGFloat(visible) * rowHeight + 16
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(L("tabs.switcher.title", "Tab Switcher"))

        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
        ])
        rows = []
        for entry in entries.prefix(visible) {
            let row = makeRow(entry, width: width - 16, height: rowHeight)
            stack.addArrangedSubview(row)
            rows.append(row)
        }
        let frame = window.frame
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2 + frame.height * 0.1))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        #if DEBUG
        debugPresentationCount += 1
        #endif
        self.panel = panel
        refreshRows()
    }

    private func makeRow(_ entry: TabSwitcherEntry, width: CGFloat, height: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.wantsLayer = true
        row.layer?.cornerRadius = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: height).isActive = true

        let marker = NSTextField(labelWithString: entry.sideLabel)
        marker.font = .systemFont(ofSize: 10, weight: .bold)
        marker.alignment = .center
        marker.textColor = .secondaryLabelColor
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 4
        marker.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        marker.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.identifier = NSUserInterfaceItemIdentifier("title")

        let path = NSTextField(
            labelWithString: (entry.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false
        path.identifier = NSUserInterfaceItemIdentifier("path")

        row.addSubview(marker)
        row.addSubview(title)
        row.addSubview(path)
        var trailing = row.trailingAnchor
        var trailingConstant: CGFloat = -10
        if entry.locked {
            let lock = NSImageView(
                image: NSImage(
                    systemSymbolName: "lock.fill",
                    accessibilityDescription: L("tabs.lockedAX", "Locked")) ?? NSImage())
            lock.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            lock.contentTintColor = .secondaryLabelColor
            lock.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(lock)
            NSLayoutConstraint.activate([
                lock.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                lock.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            trailing = lock.leadingAnchor
            trailingConstant = -6
        }
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            marker.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 20),
            marker.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailing, constant: trailingConstant),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return row
    }

    private func refreshRows() {
        guard let selection else { return }
        let accent = ThemeManager.shared.accent
        for (index, row) in rows.enumerated() {
            let selected = entries.indices.contains(index) && entries[index].id == selection.chosen
            row.layer?.backgroundColor =
                selected ? accent.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
            for case let label as NSTextField in row.subviews where label.identifier != nil {
                label.textColor =
                    selected
                    ? .white
                    : (label.identifier?.rawValue == "title" ? .labelColor : .secondaryLabelColor)
            }
        }
        if let index = entries.firstIndex(where: { $0.id == selection.chosen }),
            let entry = entries[safe: index]
        {
            NSAccessibility.post(
                element: panel as Any, notification: .announcementRequested,
                userInfo: [.announcement: "\(entry.sideLabel) \(entry.title)"])
        }
    }

    #if DEBUG
    /// The panel's content view, for the in-process render hook.
    var debugContentView: NSView? { panel?.contentView }
    var debugPanel: NSPanel? { panel }
    private(set) var debugPresentationCount = 0
    func debugSelectNext() {
        selection?.advance(reverse: false)
        refreshRows()
    }
    #endif
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
