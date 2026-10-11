#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func runLayoutUIAutomation() -> Never {
        var passed = 0
        var total = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            total += 1
            if ok { passed += 1 }
            FileHandle.standardOutput.write(
                Data("LAYOUTUI: \(ok ? "PASS" : "FAIL") \(name) \(detail)\n".utf8))
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        func contained(_ child: NSRect, in parent: NSRect) -> Bool {
            child.width > 0 && child.height > 0
                && parent.insetBy(dx: -1, dy: -1).contains(child)
        }
        func finish() -> Never {
            print("RESULT: \(passed == total ? "PASS" : "FAIL") (\(passed)/\(total))")
            exit(passed == total ? 0 : 1)
        }
        guard let window = view.window, let pane = activePane, let other = otherPane else {
            check("window-and-two-panes", false)
            finish()
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-layout-\(UUID())")
        let destination = root.appendingPathComponent("destination")
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for index in 0..<80 {
                try "fixture".write(
                    to: root.appendingPathComponent(String(format: "file-%03d.txt", index)),
                    atomically: true, encoding: .utf8)
            }
            try "different folder".write(
                to: destination.appendingPathComponent("file-079.txt"), atomically: true,
                encoding: .utf8)
        } catch {
            check("fixture-created", false, error.localizedDescription)
            finish()
        }
        let good = NSRect(x: 0, y: 0, width: 100, height: 100)
        check("geometry-good-control", contained(good, in: good))
        check("geometry-zero-control", !contained(.zero, in: good))
        check("geometry-outside-control", !contained(good.offsetBy(dx: 101, dy: 0), in: good))
        check("geometry-clipped-control", !contained(good.offsetBy(dx: 20, dy: 0), in: good))
        pane.navigate(to: root)
        other.navigate(to: root)
        check(
            "both-fixtures-delivered",
            settle { pane.debugEntryCount == 81 && other.debugEntryCount == 81 })
        for mode in ViewFormat.ViewMode.allCases {
            pane.debugClickViewSwitcher(mode)
            check(
                "actual-mode-\(mode.rawValue)",
                settle { pane.viewMode == mode && pane.debugEntryCount == 81 })
            pane.select(name: "file-079.txt")
            for size in [
                NSSize(width: 720, height: 420), NSSize(width: 1200, height: 820),
                NSSize(width: 1600, height: 1000),
            ] {
                window.setContentSize(size)
                for ratio in [0.25, 0.5, 0.75] {
                    setRightPaneFraction(ratio)
                    view.layoutSubtreeIfNeeded()
                    let label = "\(mode.rawValue)-\(Int(size.width))-\(ratio)"
                    let left = pane.containerView.convert(pane.containerView.bounds, to: view)
                    let right = other.containerView.convert(other.containerView.bounds, to: view)
                    let clip = pane.contentClipView.convert(pane.contentClipView.bounds, to: view)
                    check(
                        "geometry-\(label)",
                        contained(left, in: view.bounds) && contained(right, in: view.bounds)
                            && contained(clip, in: left) && !left.intersects(right),
                        "pane=\(left) clip=\(clip)")
                    check(
                        "selection-\(label)", pane.selectedEntries.map(\.name) == ["file-079.txt"])
                    // Explicit reveal must make the selection visible at the new geometry.
                    _ = settle {
                        pane.contentClipView.bounds.width == pane.contentClipView.frame.width
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    view.layoutSubtreeIfNeeded()
                    pane.select(name: "file-079.txt")
                    let visible = settle {
                        pane.selectionRectInWindow.map {
                            $0.intersects(
                                pane.contentClipView.convert(pane.contentClipView.bounds, to: nil))
                        } ?? false
                    }
                    func collection(in node: NSView) -> NSCollectionView? {
                        if let found = node as? NSCollectionView { return found }
                        return node.subviews.lazy.compactMap { collection(in: $0) }.first
                    }
                    let grid = collection(in: pane.containerView)
                    let attributes = grid?.selectionIndexPaths.first.flatMap {
                        grid?.layoutAttributesForItem(at: $0)?.frame
                    }
                    check(
                        "reveal-\(label)", visible,
                        visible
                            ? ""
                            : "selection=\(String(describing: pane.selectionRectInWindow)) clip=\(pane.contentClipView.bounds) document=\(String(describing: grid?.frame)) item=\(String(describing: attributes)) visible=\(String(describing: grid?.visibleRect))"
                    )
                }
            }
        }
        pane.debugClickViewSwitcher(.list)
        check(
            "drawer-list-delivered", settle { pane.viewMode == .list && pane.debugEntryCount == 81 }
        )
        for size in [NSSize(width: 720, height: 420), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            setRightPaneFraction(0.5)
            for surface in ["sidebar", "preview", "drop-stack", "terminal-frame", "torrent-frame"] {
                switch surface {
                case "sidebar": toggleCompactSidebar()
                case "preview": previewPane.toggle()
                case "drop-stack": setShelfVisible(true)
                case "terminal-frame": terminal.view.isHidden = false
                default: torrentDrawer.view.isHidden = false
                }
                view.layoutSubtreeIfNeeded()
                let left = pane.containerView.convert(pane.containerView.bounds, to: view)
                let clip = pane.contentClipView.convert(pane.contentClipView.bounds, to: view)
                check(
                    "drawer-\(surface)-\(Int(size.width))",
                    contained(left, in: view.bounds) && contained(clip, in: left),
                    "pane=\(left) clip=\(clip)")
                switch surface {
                case "sidebar": toggleCompactSidebar()
                case "preview": previewPane.toggle()
                case "drop-stack": setShelfVisible(false)
                case "terminal-frame": terminal.view.isHidden = true
                default: torrentDrawer.view.isHidden = true
                }
            }
        }
        // A queued operation survives a view swap in its origin, and runs exactly once.
        var originCallbacks = 0
        pane.selectWhenListed("file-079.txt") { originCallbacks += 1 }
        pane.debugClickViewSwitcher(.tree)
        check(
            "origin-creation-after-view-swap",
            settle { originCallbacks == 1 && pane.selectedEntries.map(\.name) == ["file-079.txt"] })
        pane.reload()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check("origin-callback-consumed-once", originCallbacks == 1)
        // No run-loop turn between arming and navigating: deterministically expose whether
        // the next *different* listing consumes a creation callback from the old folder.
        var wrongFolderCallback = false
        pane.selectWhenListed("file-079.txt") { wrongFolderCallback = true }
        pane.navigate(to: destination)
        check(
            "race-destination-delivered",
            settle { pane.currentURL.path == destination.path && pane.debugEntryCount == 1 })
        check("creation-callback-does-not-cross-directory", !wrongFolderCallback)
        check("creation-selection-does-not-cross-directory", pane.selectedEntries.isEmpty)
        try? fm.removeItem(at: root)
        finish()
    }
}
#endif
