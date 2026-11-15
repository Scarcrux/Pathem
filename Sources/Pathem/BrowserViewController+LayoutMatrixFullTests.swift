#if DEBUG
import AppKit
import PathemEngine
import TorrentKit

@MainActor
extension BrowserViewController {
    func runFullLayoutMatrix(
        demo: DemoWorkspace.Layout,
        inspect: (String) -> Void,
        check: (String, Int, Bool, NSView?, String) -> Void,
        settle: (() -> Bool) -> Bool,
        frames: () -> [NSRect], selection: () -> [String], viewport: () -> String?
    ) {
        guard let window = view.window, let left = leftTabs.activePane,
            let right = rightTabs.activePane
        else { return }
        struct Cell {
            let name: String
            let size: NSSize
            let mode: ViewFormat.ViewMode
            let panel: String
            var dark = true
            var matching = false
            var ratio = 0.5
            var resize = false
        }
        let modes: [ViewFormat.ViewMode] = [.list, .icon, .gallery, .column, .tree]
        let sizes = [
            ("minimum", NSSize(width: 720, height: 420)),
            ("default", NSSize(width: 1100, height: 700)),
            ("wide", NSSize(width: 1680, height: 1000)),
        ]
        let panels = [
            "sidebar-hidden", "compact-sidebar", "preview", "terminal", "torrent", "drop-stack",
            "detail",
        ]
        var plan: [Cell] = []
        for (sizeName, size) in sizes {
            for mode in modes {
                plan.append(
                    Cell(
                        name: "\(sizeName)-\(mode.rawValue)-none", size: size, mode: mode,
                        panel: "none"))
            }
            for mode in sizeName == "default" ? modes : [.list] {
                for panel in panels {
                    plan.append(
                        Cell(
                            name: "\(sizeName)-\(mode.rawValue)-\(panel)", size: size, mode: mode,
                            panel: panel))
                }
            }
        }
        let defaultSize = sizes[1].1
        for mode in modes {
            for panel in ["terminal+torrent", "preview+terminal"] {
                plan.append(
                    Cell(
                        name: "default-\(mode.rawValue)-\(panel)", size: defaultSize, mode: mode,
                        panel: panel))
            }
            if mode != .list {
                plan.append(
                    Cell(
                        name: "default-\(mode.rawValue)-matching", size: defaultSize, mode: mode,
                        panel: "none", matching: true))
            }
        }
        for ratio in [0.25, 0.75] {
            plan.append(
                Cell(
                    name: "default-list-ratio-\(Int(ratio*100))", size: defaultSize, mode: .list,
                    panel: "none", ratio: ratio))
        }
        let defaultRow = plan.filter { $0.size == defaultSize }
        for var cell in defaultRow {
            cell.dark = false
            plan.append(cell)
        }
        for index in [0, 2, 1] {
            plan.append(
                Cell(
                    name: "resize-\(sizes[index].0)", size: sizes[index].1, mode: .list,
                    panel: "none", resize: true))
        }
        check("plan", 0, plan.count == 139, view, "cells=\(plan.count) dropped=none")
        print("LAYOUTMATRIX: PLAN cells=\(plan.count) dropped=none budgetSeconds=240")

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }
        func mode(_ pane: PaneController, _ desired: ViewFormat.ViewMode) -> Bool {
            pane.debugClickViewSwitcher(desired)
            return settle { pane.viewMode == desired && pane.debugHasEntry("Tromsø Aurora.jpg") }
        }
        func panel(_ name: String, shown: Bool) {
            switch name {
            case "none": break
            case "sidebar-hidden":
                // The app has no hide-sidebar command. Stage the supported split's
                // hidden-subview state directly; compact mode uses the real command.
                sidebar.containerView.isHidden = shown
                outerSplit.adjustSubviews()
            case "compact-sidebar":
                if compactSidebar != shown { toggleCompactSidebar() }
            case "preview":
                if previewPane.isVisible != shown { togglePreviewPane() }
            case "terminal":
                if terminal.view.isHidden == shown { toggleTerminal() }
            case "torrent":
                if shown { showTorrentsDrawer() } else { hideTorrentsDrawer() }
            case "drop-stack": setShelfVisible(shown)
            case "detail":
                if shown {
                    torrentDetail.debugStageMatrixDetail(
                        TorrentSession.Status(
                            infoHash: String(repeating: "0", count: 40), name: "Demo download.iso",
                            totalLength: 1024, downloaded: 512, fractionComplete: 0.5,
                            downloadRate: 1000, peersConnected: 3, state: .downloading,
                            savePath: demo.root.path))
                    torrentDetail.isHidden = false
                } else {
                    hideTorrentDetail()
                }
            default:
                let parts = name.split(separator: "+").map(String.init)
                for part in shown ? parts : parts.reversed() { panel(part, shown: shown) }
            }
            layout()
        }
        let expectedSelection = selection()
        var count = 0
        let started = Date()
        for cell in plan {
            autoreleasepool {
                let label = cell.name + (cell.dark ? "-dark" : "-light")
                let incomingSelection = selection()
                let oldViewport = viewport()
                let viewSwitch =
                    left.viewMode != cell.mode
                    || right.viewMode != (cell.matching ? cell.mode : .list)
                let delivered =
                    mode(left, cell.mode) && mode(right, cell.matching ? cell.mode : .list)
                if cell.resize && count == plan.count - 3 {
                    window.setContentSize(defaultSize)
                    setRightPaneFraction(0.5)
                    layout()
                }
                window.appearance = NSAppearance(named: cell.dark ? .darkAqua : .aqua)
                window.setContentSize(cell.size)
                if !cell.resize { setRightPaneFraction(cell.ratio) }
                layout()
                let beforeFrames = frames()
                let baseline = viewport()
                var selectionKept = LayoutMatrixGeometry.sameSelection(
                    expectedSelection, selection())
                let setupSelection = selection()
                var viewportKept = baseline != nil
                if !viewSwitch {
                    viewportKept =
                        viewportKept && LayoutMatrixGeometry.sameViewport(oldViewport, baseline)
                }
                if viewSwitch {
                    print("LAYOUTMATRIX: EXEMPT \(label) check7 setup-view-switch-only")
                }
                panel(cell.panel, shown: true)
                inspect(label)
                let shownSelection = selection()
                selectionKept =
                    selectionKept
                    && LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                viewportKept =
                    viewportKept && LayoutMatrixGeometry.sameViewport(baseline, viewport())
                panel(cell.panel, shown: false)
                selectionKept =
                    selectionKept
                    && LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                viewportKept =
                    viewportKept && LayoutMatrixGeometry.sameViewport(baseline, viewport())
                check(label, 0, delivered, left.containerView, "mode/fixture delivered")
                check(
                    label, 6, selectionKept, left.containerView,
                    "expected=\(expectedSelection) incoming=\(incomingSelection) setup=\(setupSelection) shown=\(shownSelection) restored=\(selection())"
                )
                check(
                    label, 7, viewportKept, left.contentClipView,
                    "before=\(String(describing: baseline)) after=\(String(describing: viewport()))"
                )
                if cell.panel != "none" {
                    check(
                        label, 8, LayoutMatrixGeometry.sameFrames(beforeFrames, frames()),
                        outerSplit, "before=\(beforeFrames) after=\(frames())")
                } else {
                    print("LAYOUTMATRIX: EXEMPT \(label) check8 no-panel-toggle")
                }
                count += 1
            }
        }
        check(
            "full-completion", 0, count == 139 && Date().timeIntervalSince(started) < 240, view,
            "cells=\(count) seconds=\(Date().timeIntervalSince(started)) dropped=none")
        check(
            "full-transport-isolated", 0, !TorrentDaemonClient.shared.isRunning, view,
            "demo-only torrent geometry")
        // Reset the host geometry before the shared native Rename regression control.
        window.setContentSize(defaultSize)
        layout()
    }
}
#endif
