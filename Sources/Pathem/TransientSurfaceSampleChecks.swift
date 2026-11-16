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
    static func geometry(_ root: NSView, alert: NSAlert? = nil) -> [Issue] {
        var issues: [Issue] = []
        let visible = walk(root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let buttons = visible.compactMap { $0 as? NSButton }
        let controls = visible.filter { node in
            (node is NSButton || node is NSTextField)
                && !buttons.contains { node !== $0 && node.isDescendant(of: $0) }
        }
        for node in visible where node !== root && !node.visibleRect.isEmpty {
            guard let parent = node.superview else { continue }
            var ancestor: NSView? = parent
            var clippedDocument = false
            while let owner = ancestor, owner !== root {
                if owner is NSClipView { clippedDocument = true }
                ancestor = owner.superview
            }
            // A scrolling document/viewport may extend beyond its allocation;
            // measure its actually visible part. The clip view itself and all
            // controls outside it still get their full alignment-rect check.
            let rect =
                clippedDocument
                ? parent.convert(node.visibleRect, from: node)
                : LayoutMatrixGeometry.rect(node, in: parent)
            if rect.width < 1 || rect.height < 1
                || !parent.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            {
                issues.append(
                    .init(
                        number: 1, detail: "\(type(of: node)) frame=\(rect) parent=\(parent.bounds)"
                    ))
            }
            let effective =
                clippedDocument
                ? root.convert(node.visibleRect, from: node)
                : LayoutMatrixGeometry.rect(node, in: root)
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
            if let button = node as? NSButton, let cell = button.cell,
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
            let rect = LayoutMatrixGeometry.rect(node, in: root)
            for other in controls.dropFirst(index + 1)
            where !node.isDescendant(of: other) && !other.isDescendant(of: node) {
                if rect.intersects(LayoutMatrixGeometry.rect(other, in: root)) {
                    issues.append(
                        .init(
                            number: 1,
                            detail:
                                "overlap: \(type(of: node)) \(rect) / \(type(of: other)) \(LayoutMatrixGeometry.rect(other, in: root))"
                        ))
                }
            }
        }
        let ambiguous = ambiguity(root, alert: alert).app
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
    static func ambiguity(_ root: NSView, alert: NSAlert?) -> (app: [NSView], framework: [NSView]) {
        let nodes = walk(root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let editors = nodes.compactMap { $0 as? NSTextView }.filter(\.isFieldEditor)
        let ownedRoot = alert == nil ? root : alert?.accessoryView
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
