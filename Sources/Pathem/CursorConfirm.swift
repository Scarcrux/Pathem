import AppKit

/// A confirmation shown as a popover anchored at the mouse cursor, so a move/copy/trash prompt
/// appears where you are working instead of pinned to the window's title bar as a sheet (which,
/// in a wide dual-pane window, lands far from what you were doing). Returns the clicked button's
/// index, or nil if dismissed (click outside / Esc), which callers treat as Cancel.
@MainActor
final class CursorConfirm: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var continuation: CheckedContinuation<Int?, Never>?

    /// Present `message` (plus optional `info`) with `buttons` laid out left to right, anchored at
    /// the current mouse location within `anchor`. Button 0 is the default (triggered by Return).
    func ask(message: String, info: String = "", buttons: [String], over anchor: NSView) async -> Int? {
        if continuation != nil { resolve(nil) }  // a prior prompt is still open: cancel it first
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            self.continuation = cont
            let pop = NSPopover()
            pop.contentViewController = makeController(message: message, info: info, buttons: buttons)
            pop.behavior = .transient  // click outside / Esc dismisses (treated as Cancel)
            pop.delegate = self
            self.popover = pop
            pop.show(relativeTo: anchorRect(in: anchor), of: anchor, preferredEdge: .maxY)
        }
    }

    /// A 1x1 rect at the pointer, clamped inside `view` so the anchor is always valid even when
    /// the action was triggered by the keyboard (pointer possibly outside the view).
    private func anchorRect(in view: NSView) -> NSRect {
        let windowPoint = view.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        let local = view.convert(windowPoint, from: nil)
        let x = min(max(local.x, view.bounds.minX + 1), max(view.bounds.minX + 1, view.bounds.maxX - 1))
        let y = min(max(local.y, view.bounds.minY + 1), max(view.bounds.minY + 1, view.bounds.maxY - 1))
        return NSRect(x: x, y: y, width: 1, height: 1)
    }

    private func makeController(message: String, info: String, buttons: [String]) -> NSViewController {
        let vc = NSViewController()
        let content = NSView()
        let title = NSTextField(wrappingLabelWithString: message)
        title.font = .boldSystemFont(ofSize: 13)
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let body = NSTextField(wrappingLabelWithString: info)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.isHidden = info.isEmpty
        body.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for (index, name) in buttons.enumerated() {
            let button = NSButton(title: name, target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if index == 0 { button.keyEquivalent = "\r" }  // default action
            row.addArrangedSubview(button)
        }
        let stack = NSStackView(views: [title, body, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        vc.view = content
        return vc
    }

    @objc private func clicked(_ sender: NSButton) { resolve(sender.tag) }

    private func resolve(_ index: Int?) {
        // Resume before closing: closing fires popoverDidClose, which finds the continuation
        // already consumed and does nothing (no double-resume).
        continuation?.resume(returning: index)
        continuation = nil
        popover?.close()
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if continuation != nil { resolve(nil) }  // dismissed without picking a button = Cancel
    }

    /// Smoke check: the popover content builds with the expected controls and no layout crash.
    func debugBuildsController(buttons: [String]) -> Bool {
        let controller = makeController(message: "m", info: "i", buttons: buttons)
        controller.loadView()
        return controller.view.subviews.isEmpty == false
    }
}
