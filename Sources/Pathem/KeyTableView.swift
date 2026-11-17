import AppKit
import PathemEngine

/// NSTableView subclass that turns each key press into a `KeyChord` and offers
/// it to a handler. If the handler consumes it (a keymap binding fired), the key
/// is swallowed; otherwise it falls through to AppKit so arrow-key selection and
/// type-select keep working. All bindings live in the keymap, not here.
@MainActor
final class KeyTableView: NSTableView {
    /// Return true if the chord was handled (the key is then consumed).
    var onKeyChord: ((KeyChord) -> Bool)?
    /// Return true if the right-button stroke was handled (then the menu is suppressed).
    var onMouseGesture: ((String) -> Bool)?
    var onBecomeActive: (() -> Void)?

    /// The selected files for a Service (set by the owning controller; location-aware).
    var servicesURLs: (() -> [URL])?
    /// Whether the selection is local files at all. False on a remote pane, whose rows have no
    /// file URL to hand a service. Kept separate from `servicesURLs` because AppKit asks
    /// `validRequestor` on every menu update, and building every URL there would be wasteful.
    var servicesAvailable: () -> Bool = { true }
    // Services: answer for file types only with a selection and no return type, else defer.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if FileServices.accepts(
            sendType: sendType, returnType: returnType,
            hasSelection: !selectedRowIndexes.isEmpty && servicesAvailable())
        {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    @objc func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        FileServices.write(servicesURLs?() ?? [], to: pboard, types: types)
    }

    /// Alternating row stripes stop at the last real row. With the inset table style AppKit
    /// keeps drawing rounded stripes down the empty part of the list (macOS 26 and 27), which
    /// read as loading placeholders for rows that will never arrive.
    override func drawBackground(inClipRect clipRect: NSRect) {
        drawStripesOnlyBehindRows(in: clipRect) { rect in
            if !drawThemedStripes(in: rect) { super.drawBackground(inClipRect: rect) }
        }
    }
    /// A right-drag that started on a row: the super-drag flick + its swipe trail. Kept on the
    /// right button so it never collides with a left-drag (which is normal drag-and-drop).
    var onSuperDrag: ((DragSessionEvent) -> Void)?
    /// A drag left the table or ended; used to cancel a pending spring-loaded-folder open.
    var onDragExited: (() -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }
    // draggingEnded: is an OPTIONAL NSDraggingDestination method that NSView does not implement, so
    // without an explicit @objc the Swift override is never exposed to the ObjC runtime. AppKit's
    // drag-completion (CoreDragEndDragging) then sends draggingEnded:, hits "unrecognized selector",
    // and the swallowed NSException leaves the drag SESSION un-concluded -- so after any drag out to
    // another app, every later drag is silently dead until relaunch. @objc forces the selector; do
    // NOT call super (there is no NSView draggingEnded: to forward to -- super would raise the same
    // unrecognized-selector exception).
    @objc override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    private let gestureTracker = MouseGestureTracker()
    private var superDragStartRow = -1  // >= 0 means the right-drag began on a file row
    private var superDragStartWindow: NSPoint?

    // The right button: a drag starting on a row is a super-drag flick (acting on that row); a
    // drag on empty space is a navigation stroke; a plain click shows the context menu.
    override func rightMouseDown(with event: NSEvent) {
        gestureTracker.begin(event)
        superDragStartWindow = event.locationInWindow
        superDragStartRow = row(at: convert(event.locationInWindow, from: nil))
        if superDragStartRow >= 0, !selectedRowIndexes.contains(superDragStartRow) {
            selectRowIndexes([superDragStartRow], byExtendingSelection: false)  // the flick acts on it
        }
        // Draw the trail for any right-drag; the flick hint shows only for a row super-drag (empty
        // space runs a navigation stroke, not a flick).
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.began(screen: screen, showsHint: superDragStartRow >= 0))
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
        if superDragStartRow >= 0 {
            // Reduce start->end to a single cardinal (same threshold as the trail's live hint).
            let flick =
                superDragStartWindow.map {
                    MouseGesture.reduce([$0, event.locationInWindow], minSegment: 44)
                } ?? ""
            onSuperDrag?(.ended(flick: flick.isEmpty ? nil : flick))
            superDragStartRow = -1
            superDragStartWindow = nil
            if flick.isEmpty, let menu = menu(for: event) {  // no flick: treat as a plain right-click
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        onSuperDrag?(.ended(flick: nil))  // end the empty-space trail; the stroke/menu runs below
        superDragStartWindow = nil
        if let navStroke, onMouseGesture?(navStroke) == true { return }
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeActive?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let chord = KeyChord.from(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            cmd: flags.contains(.command),
            opt: flags.contains(.option),
            ctrl: flags.contains(.control),
            shift: flags.contains(.shift))
        if onKeyChord?(chord) == true { return }
        super.keyDown(with: event)
    }

    /// A menu for right-clicking the empty area below the rows (folder-level actions like
    /// Copy Path of the current folder). Falls back to the item menu when nil.
    var onBackgroundMenu: (() -> NSMenu?)?
    /// A middle-click on a row (used to open a folder in a new tab).
    var onMiddleClick: ((Int) -> Void)?

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {  // the middle button
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 {
                onMiddleClick?(row)
                return
            }
        }
        super.otherMouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)  // the right-clicked pane becomes active
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes([row], byExtendingSelection: false)  // act on the clicked item
            }
        } else {
            deselectAll(nil)  // empty space: folder-level actions only
            if let background = onBackgroundMenu?() { return background }
        }
        return super.menu(for: event)
    }
}

extension NSTableView {
    /// Under a tinted theme, draw the alternate-row stripes in a shade of the theme's background
    /// instead of AppKit's system gray. False (draw nothing) when there is no tint, or when this
    /// table shows its own background (a folder color or picture), so AppKit draws as usual.
    @MainActor func drawThemedStripes(in rect: NSRect) -> Bool {
        guard let stripe = ThemeManager.shared.stripeColor,
            backgroundColor == ThemeManager.shared.contentBackground
        else { return false }
        backgroundColor.setFill()
        rect.fill()
        stripe.setFill()
        let visible = rows(in: rect)
        for row in visible.location..<(visible.location + visible.length) where row % 2 == 1 {
            rect.intersection(self.rect(ofRow: row)).fill()
        }
        return true
    }

    /// Shared by the list and tree views: fill the clip with the plain background, then let
    /// AppKit draw its alternating stripes only over the rows that exist.
    func drawStripesOnlyBehindRows(in clipRect: NSRect, drawStripes: (NSRect) -> Void) {
        guard usesAlternatingRowBackgroundColors else {
            drawStripes(clipRect)
            return
        }
        let lastRowBottom = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
        let rows = NSRect(x: bounds.minX, y: 0, width: bounds.width, height: lastRowBottom)
        backgroundColor.setFill()
        clipRect.fill()
        let striped = clipRect.intersection(rows)
        guard !striped.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: striped).addClip()
        drawStripes(striped)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The list's column header. AppKit's header draws a system material that ignores the window
/// background, so under a tinted theme it showed as a wallpaper-tinted gray strip; with a tint
/// this draws the header itself (background, titles, sort arrow, separators). Without one it is
/// the stock header.
final class ThemedHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        guard let fill = ThemeManager.shared.headerBackground, let table = tableView else {
            super.draw(dirtyRect)
            return
        }
        fill.setFill()
        dirtyRect.fill()
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            var title = rect.insetBy(dx: 4, dy: 0)
            if let arrow = table.indicatorImage(in: column) {
                let size = arrow.size
                let frame = NSRect(
                    x: rect.maxX - size.width - 8, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height)
                let tinted = NSImage(size: size, flipped: false) { bounds in
                    arrow.draw(in: bounds)
                    NSColor.secondaryLabelColor.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: frame)
                title.size.width -= size.width + 8
            }
            // drawInterior puts the title at the top of the frame; center it vertically.
            let height = column.headerCell.cellSize.height
            title.origin.y = rect.midY - height / 2
            title.size.height = height
            column.headerCell.drawInterior(withFrame: title, in: self)
            NSColor.separatorColor.setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY + 5, width: 1, height: rect.height - 10).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// A vertical scroller whose track takes the theme's background. With "always show scroll bars"
/// the stock track is a system-colored strip beside themed rows; without a tint, or with overlay
/// scrollers (which draw no track), it is the stock scroller.
final class ThemedScroller: NSScroller {
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard let background = ThemeManager.shared.windowTint else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }
        ThemeManager.shifted(background, by: 0.03).setFill()
        slotRect.fill()
    }
}
