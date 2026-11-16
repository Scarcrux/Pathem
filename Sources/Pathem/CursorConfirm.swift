import AppKit

/// A confirmation shown as a popover anchored at the mouse cursor, so a move/copy/trash prompt
/// appears where you are working instead of pinned to the window's title bar as a sheet (which,
/// in a wide dual-pane window, lands far from what you were doing). Returns the clicked button's
/// index, or nil if dismissed (click outside / Esc), which callers treat as Cancel.
@MainActor
final class CursorConfirm: NSObject, NSPopoverDelegate {
    private static let contentWidth: CGFloat = 500
    private static let horizontalInset: CGFloat = 24
    private static let verticalInset: CGFloat = 20
    private static let buttonSpacing: CGFloat = 14
    private static let minimumButtonWidth: CGFloat = 88

    private var popover: NSPopover?
    private var continuation: CheckedContinuation<Int?, Never>?

    /// Present `message` (plus optional `info`) with `buttons` laid out left to right, anchored at
    /// the current mouse location within `anchor`. The explicit default index owns Return.
    func ask(
        message: String, info: String = "", buttons: [String], defaultIndex: Int = 0,
        cancelIndex: Int? = nil, over anchor: NSView
    ) async
        -> Int?
    {
        // A second command must not replace a decision the user is still reading.
        // Treat the new request as refused; the current prompt retains ownership.
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            self.continuation = cont
            let pop = NSPopover()
            pop.contentViewController = makeController(
                message: message, info: info, buttons: buttons, defaultIndex: defaultIndex,
                cancelIndex: cancelIndex)
            pop.behavior = .transient  // click outside / Esc dismisses (treated as Cancel)
            pop.delegate = self
            self.popover = pop
            #if DEBUG
            debugAnchorWindowNumber = anchor.window?.windowNumber
            #endif
            pop.show(relativeTo: anchorRect(in: anchor), of: anchor, preferredEdge: .maxY)
        }
    }

    /// A 1x1 rect at the pointer, clamped inside `view` so the anchor is always valid even when
    /// the action was triggered by the keyboard (pointer possibly outside the view).
    private func anchorRect(in view: NSView) -> NSRect {
        let windowPoint = view.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        let local = view.convert(windowPoint, from: nil)
        let x = min(
            max(local.x, view.bounds.minX + 1), max(view.bounds.minX + 1, view.bounds.maxX - 1))
        let y = min(
            max(local.y, view.bounds.minY + 1), max(view.bounds.minY + 1, view.bounds.maxY - 1))
        return NSRect(x: x, y: y, width: 1, height: 1)
    }

    private func makeController(
        message: String, info: String, buttons: [String], defaultIndex: Int = 0,
        cancelIndex: Int? = nil
    )
        -> NSViewController
    {
        let vc = NSViewController()
        let content = NSView()
        let title = NSTextField(wrappingLabelWithString: message)
        title.font = .boldSystemFont(ofSize: 13)
        title.maximumNumberOfLines = 0
        title.translatesAutoresizingMaskIntoConstraints = false
        let body = NSTextField(wrappingLabelWithString: info)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.isHidden = info.isEmpty
        body.maximumNumberOfLines = 0
        body.translatesAutoresizingMaskIntoConstraints = false

        var actionButtons: [NSButton] = []
        for (index, name) in buttons.enumerated() {
            let button = NSButton(title: name, target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if index == defaultIndex {
                button.keyEquivalent = "\r"
            } else if index == cancelIndex {
                button.keyEquivalent = "\u{1b}"
            }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumButtonWidth)
                .isActive = true
            actionButtons.append(button)
        }

        // Four short English actions fit comfortably in one native row. Some translations do not:
        // decide from the controls' real intrinsic widths and stack them rather than squeezing or
        // truncating their labels. The content remains deliberately wider than its minimum fitting
        // size, so the common row has breathing room instead of hugging four buttons.
        let availableActionWidth = Self.contentWidth - 2 * Self.horizontalInset
        let naturalActionWidth =
            actionButtons.reduce(CGFloat.zero) {
                $0 + max($1.fittingSize.width, Self.minimumButtonWidth)
            } + Self.buttonSpacing * CGFloat(max(0, actionButtons.count - 1))
        let stacksActions = naturalActionWidth > availableActionWidth
        let actions = NSStackView(views: actionButtons)
        actions.orientation = stacksActions ? .vertical : .horizontal
        actions.alignment = stacksActions ? .trailing : .centerY
        actions.spacing = stacksActions ? 8 : Self.buttonSpacing
        actions.translatesAutoresizingMaskIntoConstraints = false
        if stacksActions, let first = actionButtons.first {
            first.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
            for button in actionButtons.dropFirst() {
                button.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            }
        }

        content.addSubview(title)
        content.addSubview(body)
        content.addSubview(actions)
        let bodyTop = body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6)
        let actionsTop = actions.topAnchor.constraint(
            equalTo: info.isEmpty ? title.bottomAnchor : body.bottomAnchor, constant: 16)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.verticalInset),
            title.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.horizontalInset),
            title.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.horizontalInset),
            bodyTop,
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            actionsTop,
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: title.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            actions.bottomAnchor.constraint(
                equalTo: content.bottomAnchor, constant: -Self.verticalInset),
        ])
        vc.view = content
        content.layoutSubtreeIfNeeded()
        vc.preferredContentSize = content.fittingSize
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
        // A replaced popover finishes closing after the next prompt has started; its late
        // close must not cancel that newer prompt. Only the current popover's close is a
        // dismissal (click outside / Esc), which resolves as Cancel.
        let isCurrent = (notification.object as? NSPopover) === popover
        let wasPending = continuation != nil
        if isCurrent, continuation != nil { resolve(nil) }
        #if DEBUG
        debugCloseEvents.append(
            (current: isCurrent, pending: wasPending, resolved: wasPending && continuation == nil))
        #endif
    }

    #if DEBUG
    /// Every delegate close, in order: whether the closing popover was the current one, and
    /// whether a prompt was pending when it arrived, and whether this close resolved it.
    /// See docs/CURSOR_CONFIRM_LIFECYCLE.md.
    var debugCloseEvents: [(current: Bool, pending: Bool, resolved: Bool)] = []
    private(set) var debugAnchorWindowNumber: Int?
    var debugPopover: NSPopover? { popover }
    var debugHasPendingContinuation: Bool { continuation != nil }
    func debugController(
        message: String, info: String, buttons: [String], defaultIndex: Int = 0,
        cancelIndex: Int? = nil
    )
        -> NSViewController
    {
        makeController(
            message: message, info: info, buttons: buttons, defaultIndex: defaultIndex,
            cancelIndex: cancelIndex)
    }
    #endif

    /// Smoke check: the popover content builds with the expected controls and no layout crash.
    func debugBuildsController(buttons: [String]) -> Bool {
        let controller = makeController(message: "m", info: "i", buttons: buttons)
        controller.loadView()
        return controller.view.subviews.isEmpty == false
    }

    /// Layout regression checks for the compact English row and the adaptive long-label fallback.
    /// These inspect the actual Auto Layout result instead of merely proving construction succeeds.
    func debugLayoutIsComfortable(buttons: [String], expectsStacked: Bool) -> Bool {
        let controller = makeController(
            message: "1 item already exists", info: "Choose an action.", buttons: buttons)
        controller.loadView()
        let view = controller.view
        view.setFrameSize(controller.preferredContentSize)
        view.layoutSubtreeIfNeeded()
        guard let actions = view.subviews.compactMap({ $0 as? NSStackView }).first,
            actions.arrangedSubviews.count == buttons.count
        else { return false }
        let stacked = actions.orientation == .vertical
        let widthsComfortable = actions.arrangedSubviews.allSatisfy {
            $0.frame.width >= Self.minimumButtonWidth - 0.5
        }
        let rightInset = view.bounds.maxX - actions.frame.maxX
        let bottomInset = actions.frame.minY - view.bounds.minY
        return view.bounds.width >= Self.contentWidth - 0.5
            && stacked == expectsStacked
            && widthsComfortable
            && rightInset >= Self.horizontalInset - 0.5
            && bottomInset >= Self.verticalInset - 0.5
    }

    /// Render the popover content to a PNG (PATHEM_CONFLICT_SHOT) to inspect button padding. The
    /// NSPopover bubble/tail is drawn by AppKit and isn't in this content view, so we paint a
    /// backing so the edges (and the inset around the buttons) are visible.
    func debugRender(
        to path: String, message: String, info: String, buttons: [String],
        defaultIndex: Int = 0,
        cancelIndex: Int? = nil,
        appearance: NSAppearance? = nil
    ) {
        let vc = makeController(
            message: message, info: info, buttons: buttons, defaultIndex: defaultIndex,
            cancelIndex: cancelIndex)
        vc.loadView()
        let v = vc.view
        v.appearance = appearance
        v.layoutSubtreeIfNeeded()
        v.setFrameSize(v.fittingSize)
        v.layoutSubtreeIfNeeded()
        v.wantsLayer = true
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        v.layer?.cornerRadius = 10
        guard v.bounds.width > 1, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            return
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            let actions =
                v.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.compactMap {
                    $0 as? NSButton
                } ?? []
            let actualDefault = actions.first { $0.keyEquivalent == "\r" }?.tag
            let actualCancel = actions.first { $0.keyEquivalent == "\u{1b}" }?.tag
            print(
                "CONFLICT SHOT: \(Int(v.bounds.width))x\(Int(v.bounds.height)) appearance=\(v.effectiveAppearance.name.rawValue) language=\(Locale.preferredLanguages.first ?? "unknown") defaultTag=\(String(describing: actualDefault)) cancelTag=\(String(describing: actualCancel)) buttons=\(buttons.joined(separator: " | "))"
            )
        }
    }
}
