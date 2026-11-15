#if DEBUG
import AppKit
import PathemEngine

/// Shared by the real tree walk, the synthetic controls and the regression probes.
@MainActor
enum LayoutMatrixGeometry {
    private static var deliveredInjections = Set<String>()
    static func traceInjection(_ name: String, _ detail: String) {
        if deliveredInjections.insert(name).inserted {
            print("LAYOUTMATRIX: INJECT \(name) \(detail)")
        }
    }
    struct Failure {
        let check: Int
        let view: NSView
        let detail: String
    }

    static var injection: String? {
        guard ProcessInfo.processInfo.environment["PATHEM_LAYOUT_MATRIX_TEST"] != nil else {
            return nil
        }
        return ProcessInfo.processInfo.environment["PATHEM_LAYOUT_MATRIX_INJECT"]
    }

    static func walk(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(walk)
    }

    static func rect(_ child: NSView, in parent: NSView) -> NSRect {
        guard let owner = child.superview else { return .zero }
        return parent.convert(child.alignmentRect(forFrame: child.frame), from: owner)
    }

    static func contained(_ child: NSView, in parent: NSView) -> Bool {
        parent.bounds.insetBy(dx: -1, dy: -1).contains(rect(child, in: parent))
    }

    static func textFits(_ label: NSTextField) -> Bool {
        guard let cell = label.cell else { return false }
        let truncates = [NSLineBreakMode.byTruncatingHead, .byTruncatingTail, .byTruncatingMiddle]
            .contains(label.lineBreakMode)
        // NSTextFieldCell's unbounded-height measurement wraps attributed table
        // names even with wraps=false, truncatingTail and usesSingleLineMode.
        // The contract permits horizontal truncation. For that explicit non-wrap
        // case measure one attributed line (including attachment/font metrics).
        // Wrapped icon labels still use the width-constrained cell measurement.
        let needed =
            truncates && !cell.wraps
            ? label.attributedStringValue.size()
            : cell.cellSize(
                forBounds: NSRect(
                    x: 0, y: 0, width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude))
        // A full-height label outside its collection item is still clipped text.
        let available =
            label.superview.map {
                rect(label, in: $0).intersection($0.bounds).height
            } ?? label.bounds.height
        return min(available, label.bounds.height) + 1 >= needed.height
            && (truncates || needed.width <= label.bounds.width + 1)
    }

    static func inspect(root: NSView, regions: [NSView], rows: [NSView]) -> [Failure] {
        var failures: [Failure] = []
        for region in regions {
            if region.frame.width < 40 || region.frame.height < 40 {
                failures.append(.init(check: 1, view: region, detail: "primary region below 40pt"))
            }
            if region.hasAmbiguousLayout {
                failures.append(.init(check: 5, view: region, detail: "hasAmbiguousLayout"))
            }
        }
        for node in walk(root) where !node.isHiddenOrHasHiddenAncestor && !node.visibleRect.isEmpty
        {
            let control =
                node is NSButton || node is NSTextField || node is NSTableView
                || node is NSCollectionView || node.superview is NSSplitView
            if control, let parent = node.superview, !(parent is NSClipView),
                !contained(node, in: parent)
            {
                failures.append(
                    .init(
                        check: 2, view: node,
                        detail: "outside \(type(of: parent)) bounds=\(parent.bounds)"))
            }
            if let label = node as? NSTextField, !label.isEditable, !label.stringValue.isEmpty,
                !textFits(label)
            {
                let needed =
                    label.cell?.cellSize(
                        forBounds: NSRect(
                            x: 0, y: 0, width: label.bounds.width,
                            height: CGFloat.greatestFiniteMagnitude)) ?? .zero
                failures.append(
                    .init(
                        check: 4, view: label,
                        detail:
                            "text=\(label.stringValue.debugDescription) needed=\(needed) font=\(label.font?.pointSize ?? 0) lines=\(label.maximumNumberOfLines) break=\(label.lineBreakMode.rawValue) wraps=\(label.cell?.wraps ?? false) parent=\(String(describing: label.superview?.bounds))"
                    ))
            }
        }
        for row in rows {
            let children = (row as? NSStackView)?.arrangedSubviews ?? row.subviews
            let visible = children.filter {
                !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }
            for (index, child) in visible.enumerated() {
                for next in visible.dropFirst(index + 1) {
                    let overlap = rect(child, in: row).intersection(rect(next, in: row))
                    if !overlap.isNull && overlap.width > 1 && overlap.height > 1 {
                        failures.append(
                            .init(
                                check: 3, view: child,
                                detail: "overlaps \(type(of: next)) frame=\(next.frame)"))
                    }
                }
            }
        }
        return failures
    }

    static func sameFrames(_ before: [NSRect], _ after: [NSRect]) -> Bool {
        before.count == after.count
            && zip(before, after).allSatisfy { a, b in
                abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                    && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
            }
    }

    static func sameSelection(_ before: [String], _ after: [String]) -> Bool {
        before.sorted() == after.sorted()
    }
    static func sameViewport(_ before: String?, _ after: String?) -> Bool {
        before != nil && before == after
    }
}

@MainActor
extension BrowserViewController {
    /// Unit 1 deliberately contains exactly three browser cells. Rename is a separate
    /// initial-frame regression control, not another matrix axis or full dialog sweep.
    func runLayoutMatrixAutomation(demo: DemoWorkspace.Layout) -> Never {
        var passed = 0
        var total = 0
        var capturedCells = Set<String>()
        let env = ProcessInfo.processInfo.environment
        let output = env["PATHEM_LAYOUT_MATRIX_OUT"] ?? demo.root.deletingLastPathComponent().path
        func check(
            _ cell: String, _ number: Int, _ ok: Bool, _ offender: NSView? = nil,
            _ detail: String = ""
        ) {
            total += 1
            if ok { passed += 1 }
            let receipt =
                (offender ?? (ok ? nil : view)).map {
                    " class=\(type(of: $0)) id=\($0.identifier?.rawValue ?? "nil") frame=\($0.frame)"
                } ?? ""
            print(
                "LAYOUTMATRIX: \(ok ? "PASS" : "FAIL") \(cell) check\(number)\(receipt) \(detail)")
            if !ok && capturedCells.insert(cell).inserted {
                debugRenderWindowAt2x(to: output + "/\(cell)-check\(number).png")
                if cell == "rename-initial-control",
                    let sheet = view.window?.attachedSheet?.contentView,
                    let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds)
                {
                    sheet.cacheDisplay(in: sheet.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: output + "/rename-sheet.png"))
                    }
                }
            }
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(4)
            repeat {
                view.layoutSubtreeIfNeeded()
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
            return condition()
        }
        func finish() -> Never {
            terminateTerminal()
            print("RESULT: \(passed == total ? "PASS" : "FAIL") (\(passed)/\(total))")
            fflush(stdout)
            exit(passed == total ? 0 : 1)
        }
        // Demo initial tabs are intentionally dispatched asynchronously to avoid
        // Launch Services reentrancy in viewDidLoad. Await that production delivery.
        let startupDelivered = settle {
            view.window != nil && leftTabs.activePane != nil && rightTabs.activePane != nil
        }
        guard startupDelivered, let window = view.window, let left = leftTabs.activePane,
            let right = rightTabs.activePane
        else {
            check("startup", 1, false, view, "missing window/panes")
            finish()
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()

        // A tiny frame-owned tree makes the four geometry controls independent.
        let synthetic = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let region = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        synthetic.addSubview(region)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        region.addSubview(row)
        let first = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 24))
        let second = NSButton(frame: NSRect(x: 110, y: 10, width: 80, height: 24))
        let label = NSTextField(labelWithString: "Known good label")
        label.frame = NSRect(x: 10, y: 60, width: 200, height: 24)
        [first, second, label].forEach { row.addSubview($0) }
        func predicates() -> Set<Int> {
            Set(
                LayoutMatrixGeometry.inspect(root: synthetic, regions: [region], rows: [row]).map(
                    \.check))
        }
        check("predicate-good", 0, predicates().isEmpty)
        let originalRegion = region.frame
        region.setFrameSize(NSSize(width: 400, height: 0))
        check("predicate-collapse", 0, predicates() == [1])
        region.frame = originalRegion
        let originalFirst = first.frame
        first.setFrameOrigin(NSPoint(x: 350, y: 10))
        check("predicate-containment", 0, predicates() == [2])
        first.frame = originalFirst
        let originalSecond = second.frame
        second.frame = first.frame
        check("predicate-overlap", 0, predicates() == [3])
        second.frame = originalSecond
        let originalLabel = label.frame
        label.setFrameSize(NSSize(width: 200, height: 3))
        check("predicate-text", 0, predicates() == [4])
        label.frame = originalLabel
        check("predicate-restored", 0, predicates().isEmpty)
        check(
            "predicate-selection", 6,
            !LayoutMatrixGeometry.sameSelection(["one"], ["two"])
                && LayoutMatrixGeometry.sameSelection(["one"], ["one"]))
        check(
            "predicate-viewport", 7,
            !LayoutMatrixGeometry.sameViewport("first", "second")
                && LayoutMatrixGeometry.sameViewport("first", "first"))
        check(
            "predicate-reversibility", 8,
            !LayoutMatrixGeometry.sameFrames([originalRegion], [.zero])
                && LayoutMatrixGeometry.sameFrames([originalRegion], [originalRegion]))
        // Create a real Auto Layout ambiguity, not an injected boolean result.
        let controlWindow = NSWindow(
            contentRect: synthetic.frame, styleMask: [], backing: .buffered, defer: false)
        controlWindow.isReleasedWhenClosed = false
        controlWindow.contentView = synthetic
        region.translatesAutoresizingMaskIntoConstraints = false
        let ambiguousConstraints = [
            region.widthAnchor.constraint(equalToConstant: 400),
            region.heightAnchor.constraint(equalToConstant: 200),
            region.leadingAnchor.constraint(equalTo: synthetic.leadingAnchor),
        ]
        NSLayoutConstraint.activate(ambiguousConstraints)
        synthetic.layoutSubtreeIfNeeded()
        check(
            "predicate-ambiguity", 0, predicates() == [5], region,
            "failed-checks=\(predicates().sorted())")
        let missingPosition = region.topAnchor.constraint(equalTo: synthetic.topAnchor)
        missingPosition.isActive = true
        synthetic.layoutSubtreeIfNeeded()
        check(
            "predicate-all-restored", 0, predicates().isEmpty, region,
            "failed-checks=\(predicates().sorted())")
        controlWindow.orderOut(nil)
        let truncationLabel = NSTextField(
            labelWithString: String(repeating: "Long filename ", count: 6))
        truncationLabel.frame = NSRect(x: 0, y: 0, width: 70, height: 24)
        truncationLabel.lineBreakMode = .byTruncatingTail
        truncationLabel.cell?.wraps = false
        check("predicate-allowed-truncation", 4, LayoutMatrixGeometry.textFits(truncationLabel))
        truncationLabel.setFrameSize(NSSize(width: 70, height: 3))
        check("predicate-truncated-short", 4, !LayoutMatrixGeometry.textFits(truncationLabel))
        truncationLabel.attributedStringValue = FileNameDecoration.decoratedName(
            "Dolomites Ridge.jpg", git: nil, dots: [.green], size: 13)
        truncationLabel.setFrameSize(NSSize(width: 70, height: 16))
        check("predicate-attributed-truncation", 4, LayoutMatrixGeometry.textFits(truncationLabel))
        truncationLabel.setFrameSize(NSSize(width: 70, height: 3))
        check("predicate-attributed-short", 4, !LayoutMatrixGeometry.textFits(truncationLabel))
        if passed != total { finish() }

        // Stage the demo once, then drive actual view switches and terminal toggling.
        var staged = false
        debugStageSiteShot("list", demo: demo) { staged = true }
        check("staging", 0, settle { staged })
        right.setViewMode(.list)
        check(
            "right-list-delivered", 0,
            settle { right.viewMode == .list && right.debugEntryCount > 0 })
        left.navigate(to: demo.root.appendingPathComponent("Photos"))
        check(
            "left-demo-delivered", 0,
            settle {
                left.currentURL.lastPathComponent == "Photos"
                    && left.debugHasEntry("Tromsø Aurora.jpg") && left.viewMode == .list
            })
        left.select(name: "Tromsø Aurora.jpg")
        let selected = left.selectedEntries.map(\.name).sorted()
        check("selection-delivered", 0, selected == ["Tromsø Aurora.jpg"])
        func selectionState() -> [String] {
            left.selectedEntries.map { "left/" + $0.name }
                + right.selectedEntries.map { "right/" + $0.name }
        }
        let expectedSelection = selectionState()
        if !terminal.view.isHidden { toggleTerminal() }

        func regions() -> [NSView] {
            var nodes: [NSView] = [left.contentClipView, right.contentClipView]
            if !sidebar.containerView.isHiddenOrHasHiddenAncestor {
                nodes.append(sidebar.containerView)
            }
            if !terminal.view.isHidden { nodes.append(terminal.view) }
            if previewPane.isVisible { nodes.append(previewPane.view) }
            if !torrentDrawer.view.isHidden { nodes.append(torrentDrawer.view) }
            if !shelf.view.isHidden { nodes.append(shelf.view) }
            if !torrentDetail.isHidden { nodes.append(torrentDetail) }
            return nodes
        }
        func frames() -> [NSRect] { regions().map { $0.convert($0.bounds, to: view) } }
        func viewport() -> String? {
            guard let l = left.debugMatrixFirstVisibleName(),
                let r = right.debugMatrixFirstVisibleName()
            else { return nil }
            return l + "/" + r
        }
        let originalFrames: [NSRect]
        func inspect(_ cell: String) {
            print("LAYOUTMATRIX: BEGIN \(cell)")
            fflush(stdout)
            view.layoutSubtreeIfNeeded()
            let rows = LayoutMatrixGeometry.walk(view).filter {
                guard let stack = $0 as? NSStackView else { return false }
                return stack.orientation == .horizontal && !stack.isHiddenOrHasHiddenAncestor
            }
            let issues = LayoutMatrixGeometry.inspect(root: view, regions: regions(), rows: rows)
            for number in 1...5 {
                let failures = issues.filter { $0.check == number }
                if failures.isEmpty {
                    check(cell, number, true)
                } else {
                    let failure = failures[0]
                    check(
                        cell, number, false, failure.view,
                        "count=\(failures.count) \(failure.detail)")
                }
            }
            // Capture even on green: the external constraint-log checker has evidence
            // for conflicts AppKit may log without marking any region ambiguous.
            if env["PATHEM_LAYOUT_MATRIX_FULL"] == nil {
                debugRenderWindowAt2x(to: output + "/\(cell).png")
            }
            print("LAYOUTMATRIX: END \(cell)")
            fflush(stdout)
        }
        if env["PATHEM_LAYOUT_MATRIX_FULL"] != nil {
            runFullLayoutMatrix(
                demo: demo, inspect: inspect, check: check, settle: settle,
                frames: frames, selection: selectionState, viewport: viewport)
        } else {
            inspect("default-list")
            originalFrames = frames()
            let beforeIcon = expectedSelection
            left.debugClickViewSwitcher(.icon)
            check("default-icon", 0, settle { left.viewMode == .icon && left.debugEntryCount > 0 })
            inspect("default-icon")
            check(
                "default-icon", 6, LayoutMatrixGeometry.sameSelection(beforeIcon, selectionState()),
                left.containerView)
            print("LAYOUTMATRIX: EXEMPT default-icon check7 view-switch")
            left.debugClickViewSwitcher(.list)
            check("return-list", 0, settle { left.viewMode == .list && left.debugEntryCount > 0 })
            check(
                "return-list", 6,
                LayoutMatrixGeometry.sameSelection(expectedSelection, selectionState()),
                left.containerView)
            print("LAYOUTMATRIX: EXEMPT return-list check7 view-switch")
            let firstVisible = viewport()
            check("viewport-delivered", 0, firstVisible != nil)
            toggleTerminal()
            view.layoutSubtreeIfNeeded()
            inspect("default-list-terminal")
            check(
                "default-list-terminal", 6,
                LayoutMatrixGeometry.sameSelection(expectedSelection, selectionState()),
                left.containerView)
            check(
                "default-list-terminal", 7,
                LayoutMatrixGeometry.sameViewport(firstVisible, viewport()),
                left.contentClipView)
            toggleTerminal()
            _ = settle {
                terminal.view.isHidden && abs(outerSplit.frame.height - vSplit.bounds.height) <= 2
            }
            check(
                "terminal-restored", 6,
                LayoutMatrixGeometry.sameSelection(expectedSelection, selectionState()),
                left.containerView)
            check(
                "terminal-restored", 7, LayoutMatrixGeometry.sameViewport(firstVisible, viewport()),
                left.contentClipView)
            check(
                "terminal-restored", 8, LayoutMatrixGeometry.sameFrames(originalFrames, frames()),
                outerSplit)
        }

        // Initial native Rename sheet, with the production suggestion accessory.
        let dialog = RenameDialogController(
            name: "fixture.txt", url: demo.root.appendingPathComponent("fixture.txt"),
            dataless: false, offerSuggestions: true, generateAutomatically: false)
        dialog.alert.beginSheetModal(for: window) { _ in }
        dialog.alert.window.contentView?.layoutSubtreeIfNeeded()
        if let accessory = dialog.alert.accessoryView, let suggestion = dialog.suggestion {
            check(
                "rename-initial-control", 2,
                LayoutMatrixGeometry.contained(suggestion.debugButton, in: accessory),
                suggestion.debugButton,
                "accessory=\(accessory.frame)")
        } else {
            check("rename-initial-control", 2, false, view, "missing suggestion")
        }
        window.endSheet(dialog.alert.window)
        dialog.alert.window.orderOut(nil)
        dialog.cancel()
        finish()
    }
}
#endif
