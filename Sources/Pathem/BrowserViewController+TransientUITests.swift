#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func runTransientUIAutomation() -> Never {
        var results: [Bool] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append(ok)
            FileHandle.standardOutput.write(
                Data("TRANSIENTUI: \(ok ? "PASS" : "FAIL") \(name) \(detail)\n".utf8))
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        func finish() -> Never {
            let count = results.filter { $0 }.count
            print("RESULT: \(count == results.count ? "PASS" : "FAIL") (\(count)/\(results.count))")
            exit(count == results.count ? 0 : 1)
        }
        func nonoverlapping(_ rects: [NSRect]) -> Bool {
            rects.enumerated().allSatisfy { index, rect in
                rects.dropFirst(index + 1).allSatisfy { !rect.intersects($0) }
            }
        }
        func buttons(in node: NSView) -> [NSButton] {
            if let button = node as? NSButton { return [button] }
            return node.subviews.flatMap { buttons(in: $0) }
        }
        guard let window = view.window else {
            check("host-window", false)
            finish()
        }
        let control = NSRect(x: 0, y: 0, width: 20, height: 20)
        check(
            "button-separated-control", nonoverlapping([control, control.offsetBy(dx: 30, dy: 0)]))
        check(
            "button-overlap-negative-control",
            !nonoverlapping([control, control.offsetBy(dx: 10, dy: 0)]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-transient-\(UUID())")
        let target = root.appendingPathComponent(
            String(repeating: "long-", count: 35) + "résumé.txt")
        let dragged = root.appendingPathComponent("dragged.txt")
        // No menu action touches these paths: this slice exercises construction and cancel.
        for count in [1, 2, 1] {
            let items =
                count == 1 ? [dragged] : [dragged, root.appendingPathComponent("second.txt")]
            withDropOntoFileMenu(dragged: items, target: target) { menu in
                check(
                    "drop-context-delivered-\(count)",
                    pendingDropContext?.dragged == items && pendingDropContext?.target == target)
                check(
                    "drop-native-actions-\(count)",
                    menu.items.filter { $0.action != nil }.count == (count == 1 ? 5 : 4))
                let replacement = menu.items.first { $0.action?.description == "dropReplace" }
                check(
                    "drop-replace-single-only-\(count)",
                    count == 1
                        ? replacement?.title.contains(target.lastPathComponent) == true
                        : replacement == nil)
                check(
                    "drop-cancel-nondestructive-\(count)",
                    menu.items.last?.action == nil
                        && menu.items.last?.title == L("common.cancel", "Cancel"))
            }
            check("drop-dismiss-clears-context-\(count)", pendingDropContext == nil)
        }
        var presentedEmpty = false
        withDropOntoFileMenu(dragged: [], target: target) { _ in presentedEmpty = true }
        check("empty-drop-does-not-present", !presentedEmpty)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for titles in [
                ["Replace", "Keep Both", "Skip", "Cancel"],
                [
                    "Vorhandene Datei vollständig ersetzen", "Beide Dateien dauerhaft behalten",
                    "Diesen Eintrag überspringen", "Übertragung vollständig abbrechen",
                ],
            ] {
                let vc = cursorConfirm.debugController(
                    message: String(repeating: "Long confirmation message. ", count: 6),
                    info: String(repeating: "Context. ", count: 8), buttons: titles)
                let content = vc.view
                content.appearance = NSAppearance(named: appearance)
                content.setFrameSize(vc.preferredContentSize)
                content.layoutSubtreeIfNeeded()
                let stack = content.subviews.compactMap { $0 as? NSStackView }.first
                let buttons = stack?.arrangedSubviews.compactMap { $0 as? NSButton } ?? []
                let rects = buttons.map { $0.convert($0.bounds, to: content) }
                check(
                    "conflict-controls-delivered-\(appearance.rawValue)-\(titles[0].count)",
                    buttons.count == 4)
                check(
                    "conflict-button-containment",
                    rects.allSatisfy {
                        $0.width >= 88 && $0.height > 10 && content.bounds.contains($0)
                    })
                // Native button frame includes alignment insets/shadow. Auto Layout spaces
                // the actual 20pt alignment rects, not their 32pt outer frames.
                let alignmentRects = buttons.map {
                    content.convert($0.alignmentRect(forFrame: $0.frame), from: $0.superview)
                }
                check(
                    "conflict-button-alignment-no-overlap", nonoverlapping(alignmentRects),
                    "alignment=\(alignmentRects)")
                check(
                    "conflict-default-action",
                    buttons.first?.keyEquivalent == "\r"
                        && buttons.dropFirst().allSatisfy { $0.keyEquivalent.isEmpty })
            }
        }
        // Real popover and continuation lifecycle, not just its content constructor.
        window.setContentSize(NSSize(width: 720, height: 420))
        window.makeKeyAndOrderFront(nil)
        var dismissed = false
        Task { @MainActor in
            let result = await cursorConfirm.ask(
                message: "Fixture confirmation", buttons: ["Continue", "Cancel"], over: view)
            dismissed = result == nil
        }
        check("popover-present-delivered", settle { cursorConfirm.debugPopover?.isShown == true })
        cursorConfirm.debugPopover?.performClose(nil)
        check(
            "popover-dismiss-resumes-cancel",
            settle { dismissed && cursorConfirm.debugPopover == nil })
        for cycle in 0..<3 {
            var result: Int?
            var completed = false
            Task { @MainActor in
                result = await cursorConfirm.ask(
                    message: "Fixture \(cycle)", buttons: ["Continue", "Cancel"], over: view)
                completed = true
            }
            check("popover-reopen-\(cycle)", settle { cursorConfirm.debugPopover?.isShown == true })
            let action =
                cursorConfirm.debugPopover?.contentViewController.map {
                    buttons(in: $0.view).first { $0.tag == 0 }
                } ?? nil
            action?.performClick(nil)
            check(
                "popover-default-completes-once-\(cycle)",
                settle { completed && result == 0 && cursorConfirm.debugPopover == nil })
        }

        let progress = TransferProgress()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var cancellations = 0
            progress.debugPanel.appearance = NSAppearance(named: appearance)
            progress.begin(verb: "Copying", over: nil) { cancellations += 1 }
            var snapshot = FileOperations.Progress()
            snapshot.totalBytes = 1_000_000
            snapshot.completedBytes = 250_000
            snapshot.currentFile = target.lastPathComponent
            progress.update(snapshot, bytesPerSecond: 20_000)
            progress.debugPanel.contentView?.layoutSubtreeIfNeeded()
            let content = progress.debugPanel.contentView!
            check(
                "progress-controls-contained",
                progress.debugControls.allSatisfy { control in
                    let rect = control.convert(control.bounds, to: content)
                    return rect.width > 10 && rect.height > 5 && content.bounds.contains(rect)
                })
            check("progress-delivered-value", abs(progress.debugBar.doubleValue - 0.25) < 0.001)
            check("progress-escape-equivalent", progress.debugCancel.keyEquivalent == "\u{1b}")
            progress.debugCancel.performClick(nil)
            progress.debugCancel.performClick(nil)
            check("progress-cancel-once", cancellations == 1 && !progress.debugCancel.isEnabled)
            progress.end()
            progress.end()
            snapshot.completedBytes = 1_000_000
            progress.update(snapshot, bytesPerSecond: 0)
            check(
                "progress-ended-no-stale-update",
                progress.debugBar.doubleValue == 0.25 && !progress.debugPanel.isVisible)
        }
        finish()
    }
}
#endif
