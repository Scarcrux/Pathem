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
        frames: @escaping () -> [NSRect], selection: () -> [String], viewport: () -> String?
    ) {
        guard let window = view.window, var left = leftTabs.activePane,
            var right = rightTabs.activePane
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
            var customWidth = false
            var populated = false
            var cycle = ""
        }
        let modes: [ViewFormat.ViewMode] = [.list, .icon, .gallery, .column, .tree]
        let sizes = [
            ("minimum", NSSize(width: 720, height: 420)),
            ("default", NSSize(width: 1100, height: 700)),
            ("wide", NSSize(width: 1680, height: 1000)),
        ]
        let panels = [
            "compact-sidebar", "preview", "terminal", "torrent", "drop-stack",
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
        plan.append(
            Cell(
                name: "default-list-custom-sidebar", size: defaultSize, mode: .list,
                panel: "compact-sidebar", customWidth: true))
        plan.append(
            Cell(
                name: "default-list-drop-stack-items", size: defaultSize, mode: .list,
                panel: "drop-stack", populated: true))
        plan.append(
            Cell(
                name: "default-list-view-cycle", size: defaultSize, mode: .list, panel: "none",
                cycle: "views"))
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
        plan.append(
            Cell(
                name: "resize-cycle", size: defaultSize, mode: .list, panel: "none", cycle: "sizes")
        )
        check("plan", 0, plan.count == 134, view, "cells=\(plan.count) dropped=sidebar-hidden")
        print("LAYOUTMATRIX: PLAN cells=\(plan.count) dropped=sidebar-hidden budgetSeconds=240")

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }
        func mode(_ pane: PaneController, _ desired: ViewFormat.ViewMode) -> Bool {
            pane.debugClickViewSwitcher(desired)
            return settle {
                window.displayIfNeeded()
                return pane.viewMode == desired && pane.debugHasEntry("Big Sur Coast.jpg")
                    && pane.debugMatrixTagsReady()
            }
        }
        func listScrollerReceipt(_ pane: PaneController) -> String {
            guard let table = pane.keyView as? NSTableView, let scroll = table.enclosingScrollView
            else { return "not-a-table" }
            let columns = table.tableColumns.filter { !$0.isHidden }.map {
                "\($0.identifier.rawValue)=\($0.width)"
            }
            return
                "style=\(scroll.scrollerStyle.rawValue) horizontalHidden=\(String(describing: scroll.horizontalScroller?.isHidden)) scroll=\(scroll.frame.size) clip=\(scroll.contentSize) document=\(table.frame.size) columns=\(columns)"
        }
        func stableLayout() -> Bool {
            var previous: [NSRect] = []
            var unchanged = 0
            return settle {
                layout()
                window.displayIfNeeded()
                let current = frames()
                unchanged = current == previous ? unchanged + 1 : 0
                previous = current
                return unchanged >= 2
            }
        }
        func panel(_ name: String, shown: Bool) {
            switch name {
            case "none": break
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
        var count = 0
        let started = Date()
        for cell in plan {
            autoreleasepool {
                let label = cell.name + (cell.dark ? "-dark" : "-light")
                let decorationStart = LayoutMatrixGeometry.decorationReceipts.count
                LayoutMatrixGeometry.currentCell = label + "-setup"
                // Every cell owns a fresh, settled baseline. No previous cell can
                // donate its lost selection, drawer state, sidebar width or listing.
                if !terminal.view.isHidden { toggleTerminal() }
                hideTorrentsDrawer()
                hideTorrentDetail()
                if previewPane.isVisible { togglePreviewPane() }
                shelf.clear()
                setShelfVisible(false)
                if compactSidebar { toggleCompactSidebar() }
                sidebarWidthConstraint?.constant = 200
                window.appearance = NSAppearance(named: cell.dark ? .darkAqua : .aqua)
                window.setContentSize(
                    cell.resize || cell.cycle == "sizes" ? defaultSize : cell.size)
                vSplit.adjustSubviews()
                outerSplit.adjustSubviews()
                layout()
                outerSplit.setPosition(200, ofDividerAt: 0)
                layout()
                setRightPaneFraction(cell.ratio)
                let photos = demo.root.appendingPathComponent("Photos", isDirectory: true)
                folderFormats = FolderFormats(defaultFormat: prefs.defaultFormat)
                leftTabs.restoreTabs([photos.path], active: 0)
                rightTabs.restoreTabs([photos.path], active: 0)
                guard let newLeft = leftTabs.activePane, let newRight = rightTabs.activePane else {
                    check(label, 0, false, view, "fresh pane setup failed")
                    return
                }
                left = newLeft
                right = newRight
                var delivered = true
                for pane in [left, right] {
                    pane.setViewMode(.list)
                    let generation = pane.debugListingCompletions
                    pane.navigate(to: photos)
                    let loaded = settle {
                        pane.debugListingCompletions > generation
                            && pane.debugHasEntry("Big Sur Coast.jpg")
                    }
                    delivered = loaded && delivered
                }
                // Compare canonical paths, then use the ancestor's directory URL.
                // Environment-created roots can lack a trailing directory slash;
                // URL equality then differs despite an identical filesystem path.
                if let ancestor = BreadcrumbBar.ancestors(of: left.currentURL).first(where: {
                    $0.resolvingSymlinksInPath().path == demo.root.resolvingSymlinksInPath().path
                }) {
                    if count == 0 {
                        print(
                            "LAYOUTMATRIX: DEMO rootDirectory=\(demo.root.hasDirectoryPath) ancestorDirectory=\(ancestor.hasDirectoryPath) URLMatch=\(ancestor == demo.root) canonicalPathMatch=true"
                        )
                    }
                    BreadcrumbBar.demoRoot = ancestor
                }
                let leftReady = mode(left, cell.mode)
                let rightReady = mode(right, cell.matching ? cell.mode : .list)
                applyPreferences()
                delivered =
                    leftReady && rightReady && delivered
                    && settle {
                        window.displayIfNeeded()
                        return left.debugMatrixTagsReady() && right.debugMatrixTagsReady()
                    }
                for pane in [left, right] {
                    pane.debugMatrixRefreshBreadcrumb()
                    pane.select(name: "Big Sur Coast.jpg")
                }
                let desiredSelection = ["left/Big Sur Coast.jpg", "right/Big Sur Coast.jpg"]
                delivered =
                    delivered && LayoutMatrixGeometry.sameSelection(desiredSelection, selection())
                delivered =
                    delivered
                    && [left, right].allSatisfy {
                        $0.debugMatrixBreadcrumbTitles == [L("breadcrumb.home", "Home"), "Photos"]
                    }
                // Layout/metadata are complete before the per-cell anchor is taken.
                delivered = stableLayout() && delivered
                layout()
                outerSplit.setPosition(cell.customWidth ? 250 : 200, ofDividerAt: 0)
                layout()
                setRightPaneFraction(cell.ratio)
                layout()
                if !cell.customWidth { delivered = stableLayout() && delivered }
                delivered =
                    delivered
                    && abs(sidebar.containerView.frame.width - (cell.customWidth ? 250 : 200)) <= 1
                let expectedSelection = selection()
                let setupSelectionDelivered = LayoutMatrixGeometry.sameSelection(
                    desiredSelection, expectedSelection)
                delivered = delivered && setupSelectionDelivered
                let beforeFrames = frames()
                let beforeScroller =
                    right.viewMode == .list && cell.panel != "none"
                    ? listScrollerReceipt(right) : ""
                let baseline = viewport()
                var selectionKept = true
                var viewportKept = baseline != nil
                var transitionReceipt = ""
                var galleryPreviewFollowed = true
                LayoutMatrixGeometry.currentCell = label + "-transition"
                if cell.populated {
                    shelf.add([photos.appendingPathComponent("Big Sur Coast.jpg")])
                }
                panel(cell.panel, shown: true)
                if cell.resize {
                    window.setContentSize(cell.size)
                    layout()
                }
                if cell.cycle == "views" {
                    var previous = ViewFormat.ViewMode.list
                    for next in modes.dropFirst() + [.list] {
                        let arrived = mode(left, next)
                        delivered = arrived && delivered
                        if !LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                            && transitionReceipt.isEmpty
                        {
                            transitionReceipt =
                                "lost-on=\(previous.rawValue)->\(next.rawValue) names=\(selection())"
                        }
                        selectionKept =
                            selectionKept
                            && LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                        if next == .gallery {
                            galleryPreviewFollowed =
                                left.debugMatrixGalleryPreviewFollowsSelection()
                            selectionKept = selectionKept && galleryPreviewFollowed
                        }
                        previous = next
                    }
                    print(
                        "LAYOUTMATRIX: EXEMPT \(label) check7 intentional-view-navigation-only; decoration viewport still checked"
                    )
                }
                if cell.cycle == "sizes" {
                    for index in [0, 2, 1] {
                        window.setContentSize(sizes[index].1)
                        layout()
                        if !LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                            && transitionReceipt.isEmpty
                        {
                            transitionReceipt =
                                "lost-on=resize-\(sizes[index].0) names=\(selection())"
                        }
                        selectionKept =
                            selectionKept
                            && LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                        viewportKept =
                            viewportKept && LayoutMatrixGeometry.sameViewport(baseline, viewport())
                    }
                }
                delivered = stableLayout() && delivered
                inspect(label)
                let shownItemAreaHeight = shelf.debugMatrixItemAreaHeight
                let shownSelection = selection()
                selectionKept =
                    selectionKept
                    && LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                if cell.cycle != "views" {
                    viewportKept =
                        viewportKept && LayoutMatrixGeometry.sameViewport(baseline, viewport())
                }
                panel(cell.panel, shown: false)
                delivered = stableLayout() && delivered
                selectionKept =
                    selectionKept
                    && LayoutMatrixGeometry.sameSelection(expectedSelection, selection())
                if cell.cycle != "views" {
                    viewportKept =
                        viewportKept && LayoutMatrixGeometry.sameViewport(baseline, viewport())
                }
                check(
                    label, 0, delivered, left.containerView,
                    "settled cell-local baseline; sidebar=\(cell.customWidth ? 250 : 200) breadcrumb=\(left.debugMatrixBreadcrumbTitles) tagsReady=\(left.debugMatrixTagsReady()),\(right.debugMatrixTagsReady()) populated=\(cell.populated) itemAreaHeight=\(shownItemAreaHeight)"
                )
                let decorations = LayoutMatrixGeometry.decorationReceipts.dropFirst(decorationStart)
                let paneCallbacks = decorations.reduce(0) { $0 + $1.callbacks }
                let decorationsKeptSelection = decorations.allSatisfy {
                    $0.selectionKept && $0.structureKept && $0.callbacks == 0
                }
                let decorationsKeptViewport = decorations.allSatisfy {
                    $0.viewportKept && $0.structureKept
                }
                if setupSelectionDelivered {
                    check(
                        label, 6, selectionKept && decorationsKeptSelection, left.containerView,
                        "expected=\(expectedSelection) shown=\(shownSelection) restored=\(selection()) \(transitionReceipt) decorationUpdates=\(decorations.count) paneCallbacks=\(paneCallbacks) decorationSelectionKept=\(decorationsKeptSelection) galleryPreviewFollowed=\(galleryPreviewFollowed)"
                    )
                } else {
                    print(
                        "LAYOUTMATRIX: INVALID \(label) check6 setup-selection-not-delivered; check0 fails"
                    )
                }
                check(
                    label, 7, viewportKept && decorationsKeptViewport, left.contentClipView,
                    "before=\(String(describing: baseline)) after=\(String(describing: viewport())) decorationUpdates=\(decorations.count) decorationViewportKept=\(decorationsKeptViewport)"
                )
                if cell.panel != "none" {
                    let afterFrames = frames()
                    let restored = LayoutMatrixGeometry.sameFrames(beforeFrames, afterFrames)
                    let scrollers =
                        !restored && !beforeScroller.isEmpty
                        ? " scrollerBefore=[\(beforeScroller)] scrollerAfter=[\(listScrollerReceipt(right))]"
                        : ""
                    check(
                        label, 8, restored,
                        outerSplit, "before=\(beforeFrames) after=\(afterFrames)\(scrollers)")
                } else {
                    print("LAYOUTMATRIX: EXEMPT \(label) check8 no-panel-toggle")
                }
                count += 1
            }
        }
        check(
            "full-completion", 0, count == 134 && Date().timeIntervalSince(started) < 240, view,
            "cells=\(count) seconds=\(Date().timeIntervalSince(started)) dropped=sidebar-hidden")
        check(
            "full-transport-isolated", 0, !TorrentDaemonClient.shared.isRunning, view,
            "demo-only torrent geometry")
        check(
            "selection-callback-instrument", 0, LayoutMatrixGeometry.selectionCallbacks > 0, view,
            "actual pane selection callbacks observed=\(LayoutMatrixGeometry.selectionCallbacks)")
        // Reset the host geometry before the shared native Rename regression control.
        window.setContentSize(defaultSize)
        layout()
    }
}
#endif
