#if DEBUG
import AppKit

/// The native measurements and predicate controls share these exact checks.
@MainActor
enum TransientSurfaceChecks {
    struct Issue {
        let number: Int
        let detail: String
    }
    static func walk(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(walk) }
    static func diagnostic(_ node: NSView) -> String {
        var owner = node.superview
        var table: NSTableView?
        while let current = owner {
            if let value = current as? NSTableView {
                table = value
                break
            }
            owner = current.superview
        }
        let column = table.map { $0.column(for: node) } ?? -1
        let columnRect = table.flatMap {
            column >= 0 && column < $0.tableColumns.count ? $0.rect(ofColumn: column) : nil
        }
        return
            "rawFrame=\(node.frame) bounds=\(node.bounds) visible=\(node.visibleRect) insets=\(node.alignmentRectInsets) parentClass=\(node.superview.map { String(describing: type(of: $0)) } ?? "none") parentClips=\(node.superview?.clipsToBounds ?? false) wantsLayer=\(node.wantsLayer) subviews=\(node.subviews.count) textFlags=\((node as? NSTextField).map { "editable=\($0.isEditable),selectable=\($0.isSelectable),bordered=\($0.isBordered),bezeled=\($0.isBezeled),background=\($0.drawsBackground),empty=\($0.stringValue.isEmpty),placeholder=\($0.placeholderString != nil),cell=\(String(describing: $0.cell))" } ?? "none") tableColumn=\(column) columnRect=\(String(describing: columnRect))"
    }
    // A view can report a visibleRect larger than its own drawable bounds.
    // Intersect first; do not interpret that diagnostic region as painted ink.
    static func boundedVisibleRect(_ node: NSView) -> NSRect {
        let part = node.visibleRect.intersection(node.bounds)
        guard !part.isNull, !part.isInfinite,
            part.minX.isFinite, part.minY.isFinite,
            part.width.isFinite, part.height.isFinite
        else { return .zero }
        return part
    }
    static func scrollingContent(_ node: NSView, root: NSView) -> Bool {
        var owner = node.superview
        while let current = owner, current !== root {
            if current is NSClipView { return true }
            owner = current.superview
        }
        return false
    }
    static func nondrawingLeaf(_ node: NSView) -> Bool {
        guard node.subviews.isEmpty, !node.wantsLayer,
            node.layer?.contents == nil,
            (node.layer?.backgroundColor?.alpha ?? 0) == 0
        else { return false }
        if type(of: node) == NSView.self {
            return node.gestureRecognizers.isEmpty && !node.isAccessibilityElement()
        }
        guard type(of: node) == NSTextField.self, let text = node as? NSTextField,
            !text.isEditable, !text.isSelectable, !text.isBordered, !text.isBezeled,
            !text.drawsBackground, text.stringValue.isEmpty,
            text.attributedStringValue.length == 0,
            text.placeholderString?.isEmpty ?? true,
            (text.placeholderAttributedString?.length ?? 0) == 0
        else { return false }
        return true
    }
    /// This exact AppKit empty informative-label shape was independently shown
    /// to paint no pixels. Unknown helpers or app-owned controls remain measured.
    static func nondrawingAlertNodes(_ root: NSView, alert: NSAlert?) -> [NSView] {
        guard let alert, alert.window.contentView === root,
            String(describing: type(of: root)) == "_NSAlertContentView",
            !alert.messageText.isEmpty, alert.informativeText.isEmpty
        else { return [] }
        func hasNoLayerInk(_ view: NSView, allowedChild: NSView? = nil) -> Bool {
            guard let layer = view.layer else { return true }
            // AppKit caches even blank labels in a backing-layer contents
            // wrapper. The pixel experiment proved this exact empty shape
            // paints no ink; arbitrary image contents remain disallowed.
            if let contents = layer.contents {
                guard String(describing: type(of: layer)) == "NSViewBackingLayer",
                    String(describing: type(of: contents)) == "NSViewBackingLayerContents"
                else { return false }
            }
            let children = layer.sublayers ?? []
            let knownChildren =
                children.isEmpty
                || (children.count == 1 && children.first === allowedChild?.layer)
            return (layer.backgroundColor?.alpha ?? 0) == 0
                && layer.borderWidth == 0 && layer.shadowOpacity == 0
                && (layer.filters?.isEmpty ?? true) && layer.compositingFilter == nil
                && knownChildren
        }
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_GEOMETRY_DIAGNOSTIC"] == "1" {
            for field in root.subviews.compactMap({ $0 as? NSTextField })
            where field.stringValue.isEmpty {
                let child = field.subviews.first
                let text =
                    "TSAMPLE: EMPTY-GUARDS rootIdentity=\(alert.window.contentView === root) cellClass=\(field.cell.map { String(describing: type(of: $0)) } ?? "nil") attrLength=\(field.attributedStringValue.length) attributedPlaceholder=\(field.placeholderAttributedString?.length ?? 0) editor=\(field.currentEditor() != nil) fieldLayerInk=\(!hasNoLayerInk(field)) helperFrame=\(String(describing: child?.frame)) fieldBounds=\(field.bounds) helperLayerInk=\(child.map { !hasNoLayerInk($0) } ?? false) responder=\(String(describing: alert.window.firstResponder.map { type(of: $0) })) childLayer=\(String(describing: child?.layer))"
                FileHandle.standardOutput.write(Data((text + "\n").utf8))
            }
        }
        let matches = root.subviews.compactMap { node -> NSTextField? in
            guard type(of: node) == NSTextField.self, let field = node as? NSTextField,
                let cell = field.cell, type(of: cell) == NSTextFieldCell.self,
                !field.isEditable, field.isSelectable, !field.isBordered, !field.isBezeled,
                !field.drawsBackground, field.stringValue.isEmpty,
                field.attributedStringValue.length == 0,
                field.placeholderString?.isEmpty ?? true,
                (field.placeholderAttributedString?.length ?? 0) == 0,
                field.currentEditor() == nil, field.subviews.count == 1,
                hasNoLayerInk(field, allowedChild: field.subviews.first)
            else { return nil }
            if let accessory = alert.accessoryView,
                field === accessory || field.isDescendant(of: accessory)
            {
                return nil
            }
            if let responder = alert.window.firstResponder as? NSView,
                responder === field || responder.isDescendant(of: field)
            {
                return nil
            }
            let helper = field.subviews[0]
            guard String(describing: type(of: helper)) == "NSTextFieldSimpleLabel",
                helper.subviews.isEmpty, helper.frame == field.bounds,
                hasNoLayerInk(helper)
            else { return nil }
            return field
        }
        guard matches.count == 1, let field = matches.first else { return [] }
        return [field, field.subviews[0]]
    }
    static func measuredRect(_ node: NSView, in parent: NSView, root: NSView) -> NSRect {
        guard scrollingContent(node, root: root) else {
            return LayoutMatrixGeometry.rect(node, in: parent)
        }
        // AppKit control frames include non-content border padding. Keep the
        // layout matrix's alignment rectangle even inside a clipped document.
        let aligned = LayoutMatrixGeometry.rect(node, in: node)
        let painted = boundedVisibleRect(node).intersection(aligned)
        guard !painted.isNull, !painted.isInfinite else { return .zero }
        return parent.convert(painted, from: node)
    }
    final class InsetControl: NSControl {
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 5, left: 7, bottom: 6, right: 7)
        }
    }
    /// Test-only override drives the same geometry pipeline as real table cells.
    final class VisibilityLabel: NSTextField {
        var injectedVisibleRect: NSRect?
        override var visibleRect: NSRect { injectedVisibleRect ?? super.visibleRect }
    }
    struct PopupTitleMeasurement {
        let fits: Bool
        let detail: String
    }
    static func popupTitleMeasurement(_ popup: NSPopUpButton) -> PopupTitleMeasurement {
        guard let cell = popup.cell as? NSPopUpButtonCell else {
            return .init(fits: false, detail: "popup has unexpected cell")
        }
        // The SDK specifies which menu item is actually displayed. cellSize
        // sizes a popup for its menu, not just that displayed item's title.
        let item =
            cell.usesItemFromMenu
            ? (cell.pullsDown ? popup.item(at: 0) : popup.selectedItem) : cell.menuItem
        let displayed = popup.title
        let font = popup.font ?? cell.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attributed: NSMutableAttributedString
        if let title = item?.attributedTitle, title.string == displayed, title.length > 0 {
            attributed = NSMutableAttributedString(attributedString: title)
            title.enumerateAttribute(.font, in: NSRange(location: 0, length: title.length)) {
                value, range, _ in
                if value == nil { attributed.addAttribute(.font, value: font, range: range) }
            }
        } else {
            attributed = NSMutableAttributedString(string: displayed, attributes: [.font: font])
        }
        let rawTitleRect = cell.titleRect(forBounds: popup.bounds)
        let titleRect = rawTitleRect.intersection(popup.bounds)
        let needed = attributed.size().width
        let valid =
            !titleRect.isNull && !titleRect.isInfinite
            && titleRect.width.isFinite && titleRect.height.isFinite
            && needed.isFinite && (displayed.isEmpty || titleRect.width > 0)
        return .init(
            fits: valid && needed <= titleRect.width + 1,
            detail:
                "popup displayed title=\(displayed) titleRect=\(rawTitleRect) boundedTitleRect=\(titleRect) needed=\(needed) bounds=\(popup.bounds) cellSize=\(cell.cellSize) selected=\(String(describing: popup.titleOfSelectedItem)) pullsDown=\(cell.pullsDown) usesItemFromMenu=\(cell.usesItemFromMenu) valid=\(valid)"
        )
    }
    static func geometry(
        _ root: NSView, alert: NSAlert? = nil, systemAccessory: NSView? = nil,
        systemPanel: Bool = false
    ) -> [Issue] {
        var issues: [Issue] = []
        let nondrawingAlert = Set(
            nondrawingAlertNodes(root, alert: alert).map(ObjectIdentifier.init))
        let visible = walk(root).filter {
            !$0.isHiddenOrHasHiddenAncestor && !nondrawingAlert.contains(ObjectIdentifier($0))
        }
        let buttons = visible.compactMap { $0 as? NSButton }
        let controls = visible.filter { node in
            (node is NSButton || node is NSTextField) && !nondrawingLeaf(node)
                && !(scrollingContent(node, root: root) && boundedVisibleRect(node).isEmpty
                    && node.bounds.width >= 1 && node.bounds.height >= 1)
                && !buttons.contains { node !== $0 && node.isDescendant(of: $0) }
        }
        for node in visible where node !== root && !nondrawingLeaf(node) {
            guard let parent = node.superview else { continue }
            let collapsed =
                (node.bounds.width < 1 || node.bounds.height < 1)
                && (node is NSControl || !node.subviews.isEmpty)
            let clippedDocument = scrollingContent(node, root: root)
            if node.visibleRect.isEmpty && !collapsed { continue }
            // Positive-size offscreen children draw no ink. A collapsed real
            // control or container with children still has to fail minimum size.
            if clippedDocument && boundedVisibleRect(node).isEmpty && !collapsed { continue }
            let rect = measuredRect(node, in: parent, root: root)
            if rect.width < 1 || rect.height < 1
                || !parent.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            {
                issues.append(
                    .init(
                        number: 1,
                        detail:
                            "\(type(of: node)) frame=\(rect) parent=\(parent.bounds) \(diagnostic(node))"
                    ))
            }
            let effective = measuredRect(node, in: root, root: root)
            if !root.bounds.insetBy(dx: -1, dy: -1).contains(effective) {
                issues.append(
                    .init(
                        number: 1,
                        detail:
                            "control outside content: \(LayoutMatrixGeometry.rect(node, in: root)) content=\(root.bounds)"
                    ))
            }
            if let text = node as? NSTextField, !text.isEditable, !text.stringValue.isEmpty,
                !LayoutMatrixGeometry.textFits(text)
            {
                issues.append(
                    .init(
                        number: 1,
                        detail:
                            "text does not fit: \(text.stringValue.prefix(60)) frame=\(text.frame)")
                )
            }
            if let popup = node as? NSPopUpButton {
                let title = popupTitleMeasurement(popup)
                if !title.fits { issues.append(.init(number: 1, detail: title.detail)) }
            } else if let button = node as? NSButton, let cell = button.cell,
                cell.cellSize.width > button.bounds.width + 1
            {
                issues.append(
                    .init(
                        number: 1,
                        detail:
                            "button title clipped: \(button.title) width=\(button.bounds.width) needed=\(cell.cellSize.width)"
                    ))
            }
        }
        for (index, node) in controls.enumerated() {
            let rect = measuredRect(node, in: root, root: root)
            for other in controls.dropFirst(index + 1)
            where !node.isDescendant(of: other) && !other.isDescendant(of: node) {
                if !rect.isEmpty && rect.intersects(measuredRect(other, in: root, root: root)) {
                    issues.append(
                        .init(
                            number: 1,
                            detail:
                                "overlap: \(type(of: node)) \(rect) / \(type(of: other)) \(measuredRect(other, in: root, root: root))"
                        ))
                }
            }
        }
        for button in missingIconTooltips(
            root, alert: alert, systemAccessory: systemAccessory, systemPanel: systemPanel)
        {
            issues.append(
                .init(
                    number: 1,
                    detail:
                        "icon-only control has no tooltip: \(type(of: button)) \(tooltipDiagnostic(button))"
                ))
        }
        let ambiguous = ambiguity(
            root, alert: alert, systemAccessory: systemAccessory, systemPanel: systemPanel
        ).app
        if !ambiguous.isEmpty {
            issues.append(
                .init(
                    number: 3,
                    detail: "ambiguous: \(ambiguous.map { String(describing: type(of: $0)) })"))
        }
        if let alert {
            let delivered = controls.compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == alert.messageText && !$0.stringValue.isEmpty
            }
            if !delivered {
                issues.append(.init(number: 1, detail: "native message not delivered"))
            }
            if !alert.informativeText.isEmpty
                && !controls.compactMap({ $0 as? NSTextField }).contains(where: {
                    $0.stringValue == alert.informativeText
                })
            {
                issues.append(.init(number: 1, detail: "native informative text not delivered"))
            }
        }
        return issues
    }
    /// Layout ownership follows the coordinator's 2026-11-16 clarification.
    /// Private framework classes and the field editor are reported, never waived geometrically.
    static func ambiguity(
        _ root: NSView, alert: NSAlert?, systemAccessory: NSView? = nil, systemPanel: Bool = false
    ) -> (app: [NSView], framework: [NSView]) {
        let nodes = walk(root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let editors = nodes.compactMap { $0 as? NSTextView }.filter(\.isFieldEditor)
        let ownedRoot = systemPanel ? systemAccessory : (alert == nil ? root : alert?.accessoryView)
        var app: [NSView] = []
        var framework: [NSView] = []
        for node in nodes where node.hasAmbiguousLayout {
            let owned = ownedRoot.map { node === $0 || node.isDescendant(of: $0) } ?? false
            let helper =
                String(describing: type(of: node)).hasPrefix("_")
                || editors.contains { node === $0 || node.isDescendant(of: $0) }
            if owned && !helper { app.append(node) } else { framework.append(node) }
        }
        return (app, framework)
    }
    static func fits(frame: NSRect, screen: NSRect, sheet: Bool, host: NSSize) -> Bool {
        screen.insetBy(dx: -1, dy: -1).contains(frame)
            && (!sheet || (frame.width <= host.width + 1 && frame.height <= host.height + 1))
    }
    static func tooltipDiagnostic(_ button: NSButton) -> String {
        var owner = button.superview
        var ancestry: [String] = []
        var search: NSSearchField?
        while let value = owner {
            ancestry.append(String(describing: type(of: value)))
            if let field = value as? NSSearchField { search = field }
            owner = value.superview
        }
        let cell = search?.cell as? NSSearchFieldCell
        return
            "frame=\(button.frame) id=\(button.identifier?.rawValue ?? "none") imagePosition=\(button.imagePosition.rawValue) cell=\(button.cell.map { String(describing: type(of: $0)) } ?? "none") target=\(button.target.map { String(describing: type(of: $0)) } ?? "none") action=\(button.action.map(NSStringFromSelector) ?? "none") ancestry=\(ancestry) searchCell=\(cell?.searchButtonCell === button.cell) cancelCell=\(cell?.cancelButtonCell === button.cell)"
    }
    static func nativeSearchButton(_ button: NSButton) -> Bool {
        guard let buttonCell = button.cell else { return false }
        var owner = button.superview
        while let view = owner {
            if let field = view as? NSSearchField, let cell = field.cell as? NSSearchFieldCell {
                return cell.searchButtonCell === buttonCell || cell.cancelButtonCell === buttonCell
            }
            owner = view.superview
        }
        return false
    }
    static func missingIconTooltips(
        _ root: NSView, alert: NSAlert? = nil,
        systemAccessory: NSView? = nil, systemPanel: Bool = false
    ) -> [NSButton] {
        let ownedRoot = systemPanel ? systemAccessory : (alert == nil ? root : alert?.accessoryView)
        guard let ownedRoot else { return [] }
        return walk(ownedRoot).compactMap { $0 as? NSButton }.filter { button in
            !button.isHiddenOrHasHiddenAncestor && !nativeSearchButton(button)
                && button.image != nil
                && (button.imagePosition == .imageOnly
                    || button.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && (button.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    enum Presentation { case sheet, window, popover }
    static func presentation(_ expected: Presentation, parent: Int?, host: Int, popoverAnchor: Int?)
        -> Bool
    {
        switch expected {
        case .sheet: return parent == host
        case .window: return parent == nil
        case .popover: return parent == nil && popoverAnchor == host
        }
    }
    /// The measured macOS NSAlert backing window is exactly 75 points larger
    /// on every side. This exception applies only while its exact alert is up;
    /// dismissal/accumulation continue to inspect all literal visible windows.
    static func alertGlassCompanion(
        alertClass: String, alertFrame: NSRect,
        candidateClass: String, candidateFrame: NSRect, candidateSheetParent: Int?
    ) -> Bool {
        guard alertClass == "_NSAlertPanel", candidateClass == "_NSGlassEffectWindow",
            candidateSheetParent == nil, !alertFrame.isEmpty
        else { return false }
        let measured = alertFrame.insetBy(dx: -75, dy: -75)
        let differences = [
            candidateFrame.minX - measured.minX, candidateFrame.minY - measured.minY,
            candidateFrame.width - measured.width, candidateFrame.height - measured.height,
        ]
        return differences.allSatisfy { $0.isFinite && abs($0) <= 0.5 }
    }
    static func singlePresentation(
        before: [Int], after: [Int], expected: Int,
        companions: [Int] = []
    ) -> Bool {
        companions.count <= 1 && !companions.contains(expected)
            && Set(companions).isDisjoint(with: Set(before))
            && after.count == before.count + 1 + companions.count
            && Set(after).subtracting(before) == Set([expected] + companions)
            && Set(before).isSubset(of: Set(after))
    }
    static func ownership(actual: Int?, expected: Int) -> Bool { actual == expected }
    static func appearance(_ view: NSView, expected: NSAppearance.Name?) -> Bool {
        expected.map { view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == $0 } ?? true
    }
    static func unchanged(_ before: [String: Data], _ after: [String: Data]) -> Bool {
        before == after
    }
    static func defaultAction(
        actual: Int?, expected: Int, destructive: Bool, intended: Bool, delivered: Int? = nil
    ) -> Bool {
        actual == expected && (!destructive || intended)
            && (delivered == nil || delivered == expected)
    }
    static func dismissed(
        pending: Bool, visible: Bool, responderBefore: ObjectIdentifier?,
        responderAfter: ObjectIdentifier?
    ) -> Bool {
        !pending && !visible && responderBefore != nil && responderBefore == responderAfter
    }
    static func noAccumulation(before: [Int], after: [Int]) -> Bool {
        before.sorted() == after.sorted()
    }
}
#endif
