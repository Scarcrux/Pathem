#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Drive the menus installed on real views, not a detached substitute menu.
    func runFinderUIAutomation() -> Never {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append((name, ok, detail))
            let line = "FINDERUI: \(ok ? "PASS" : "FAIL") \(name) \(detail)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        func settle(_ seconds: Double = 3, until condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        func finish() -> Never {
            let passed = results.filter { $0.1 }.count
            print(
                "RESULT: \(passed == results.count ? "PASS" : "FAIL") (\(passed)/\(results.count))")
            exit(passed == results.count ? 0 : 1)
        }
        guard let window = view.window, let pane = activePane else {
            check("finder-has-window", false)
            finish()
        }
        window.setContentSize(NSSize(width: 1200, height: 820))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-finder-ui-\(UUID())")
        let source = root.appendingPathComponent("source.txt")
        let package = root.appendingPathComponent("Sample.app")
        let target = root.appendingPathComponent("ordinary/target.txt")
        do {
            try fm.createDirectory(
                at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "archive payload".write(to: source, atomically: true, encoding: .utf8)
            try "original payload".write(to: target, atomically: true, encoding: .utf8)
            try "package payload".write(
                to: package.appendingPathComponent("Contents/inside.txt"), atomically: true,
                encoding: .utf8)
            try fm.createSymbolicLink(
                at: root.appendingPathComponent("target-link"), withDestinationURL: target)
        } catch {
            check("finder-fixture", false, error.localizedDescription)
            finish()
        }
        // Each fixture lives in a unique disposable directory; never touch real user files.
        defer { try? fm.removeItem(at: root) }
        func navigateRoot() {
            pane.navigate(to: root)
            check(
                "finder-root-listed",
                settle { pane.currentURL.path == root.path && pane.debugHasEntry("source.txt") },
                "path=\(pane.currentURL.path)")
        }
        func fileMenu(in view: NSView) -> NSMenu? {
            if let menu = view.menu,
                menu.items.contains(where: { ($0.representedObject as? String) == "files.open" })
            {
                return menu
            }
            for child in view.subviews {
                if let found = fileMenu(in: child) { return found }
            }
            return nil
        }
        func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
            menu.items.first { ($0.representedObject as? String) == id }
        }
        func select(_ names: [String], menu: NSMenu) {
            pane.debugSelectNames(names)
            check(
                "finder-selection-delivered", Set(pane.selectedEntries.map(\.name)) == Set(names),
                names.joined(separator: ","))
            menu.delegate?.menuNeedsUpdate?(menu)
            window.makeFirstResponder(pane.keyView)
            // Background automation cannot acquire NSApp.keyWindow on this host. Resolve
            // and validate through this real window's responder chain instead of silently
            // accepting AppKit's disabled nil-key-window fallback as a product failure.
            for item in menu.items {
                guard let action = item.action else { continue }
                var responder: NSResponder? = window.firstResponder
                while let current = responder, !current.responds(to: action) {
                    responder = current.nextResponder
                }
                item.isEnabled =
                    (responder as? NSMenuItemValidation)?.validateMenuItem(item) ?? false
            }
        }
        func visible(_ id: String, in menu: NSMenu) -> Bool {
            item(id, in: menu).map { !$0.isHidden } ?? false
        }
        func dispatch(_ id: String, menu: NSMenu) {
            guard let item = item(id, in: menu), let action = item.action else {
                check("finder-dispatch-\(id)", false, "missing menu action")
                return
            }
            let enabled = item.isEnabled && !item.isHidden
            let routed =
                enabled && (window.firstResponder?.tryToPerform(action, with: item) ?? false)
            check(
                "finder-dispatch-\(id)", enabled && routed,
                "enabled=\(enabled) routed=\(routed) key=\(window.isKeyWindow) focus=\(String(describing: window.firstResponder)) active=\(activePane === pane)"
            )
        }
        let additions = [
            "files.compress", "files.compress7z", "files.makeAlias", "view.quickLook",
            "files.showOriginal", "files.showPackageContents",
        ]
        let applicationFileMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first {
            $0.items.contains { ($0.representedObject as? String) == "files.open" }
        }
        check(
            "finder-package-file-menu-discoverable",
            applicationFileMenu?.items.contains {
                ($0.representedObject as? String) == "files.showPackageContents"
            } == true)
        navigateRoot()
        for mode in ViewFormat.ViewMode.allCases {
            pane.debugClickViewSwitcher(mode)
            check(
                "finder-view-\(mode.rawValue)",
                settle { pane.viewMode == mode && pane.debugHasEntry("source.txt") })
            guard let menu = fileMenu(in: pane.containerView) else {
                check("finder-menu-\(mode.rawValue)", false)
                continue
            }
            check(
                "finder-entries-\(mode.rawValue)",
                additions.allSatisfy {
                    item($0, in: menu)?.image != nil && !(item($0, in: menu)?.title.isEmpty ?? true)
                })
            if mode == .gallery {
                func collections(in view: NSView) -> [NSCollectionView] {
                    (view as? NSCollectionView).map { [$0] }
                        ?? view.subviews.flatMap { collections(in: $0) }
                }
                guard let collection = collections(in: pane.containerView).first,
                    let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout,
                    let scroller = collection.enclosingScrollView
                else {
                    check("finder-gallery-instrument", false)
                    continue
                }
                for size in [
                    NSSize(width: 720, height: 420), NSSize(width: 1200, height: 820),
                    NSSize(width: 1600, height: 1000),
                ] {
                    window.setContentSize(size)
                    view.layoutSubtreeIfNeeded()
                    for style in [NSScroller.Style.legacy, .overlay] {
                        scroller.scrollerStyle = style
                        scroller.tile()
                        let needed =
                            layout.itemSize.height + layout.sectionInset.top
                            + layout.sectionInset.bottom
                        let available = scroller.contentSize.height
                        check(
                            "finder-gallery-filmstrip-\(Int(size.width))-\(style.rawValue)",
                            available > needed,
                            "clip=\(available) item+insets=\(needed) outer=\(scroller.frame.height)"
                        )
                    }
                    scroller.scrollerStyle = .legacy
                }
                window.setContentSize(NSSize(width: 1200, height: 820))
                view.layoutSubtreeIfNeeded()
            }
            select(["source.txt"], menu: menu)
            // An ordinary local file is not an iCloud item: neither cloud entry is offered. (Real
            // iCloud items are environmental and not created here.)
            check(
                "finder-cloud-entries-absent-for-local-file-\(mode.rawValue)",
                !visible("files.download", in: menu) && !visible("files.offload", in: menu),
                "download=\(visible("files.download", in: menu)) offload=\(visible("files.offload", in: menu))"
            )
            let tagsMenu = menu.items.compactMap(\.submenu).first {
                $0.items.contains { ($0.representedObject as? String) == "tags.clear" }
            }
            check(
                "finder-named-labels-context-\(mode.rawValue)",
                tagsMenu?.items.compactMap { $0.representedObject as? FileLabel }.count
                    == LabelSet.default.labels.count)
            if let tagsMenu, let label = LabelSet.default.labels.first,
                let labelItem = tagsMenu.items.first(where: {
                    ($0.representedObject as? FileLabel) == label
                }),
                let action = labelItem.action
            {
                let second = root.appendingPathComponent("ordinary")
                do {
                    try FileTags.setTags([label.tag], on: source)
                    try FileTags.setTags([], on: second)
                    select(["source.txt", "ordinary"], menu: menu)
                    tagsMenu.delegate?.menuNeedsUpdate?(tagsMenu)
                    check(
                        "finder-label-mixed-\(mode.rawValue)",
                        labelItem.state == .mixed && validateMenuItem(labelItem))
                    check(
                        "finder-label-dispatch-\(mode.rawValue)",
                        window.firstResponder?.tryToPerform(action, with: labelItem) == true)
                    check(
                        "finder-label-written-both-\(mode.rawValue)",
                        [source, second].allSatisfy { FileTags.tags(of: $0).contains(label.tag) })
                    check(
                        "finder-label-refresh-keeps-selection-\(mode.rawValue)",
                        Set(pane.selectedEntries.map(\.name)) == ["source.txt", "ordinary"])
                    tagsMenu.delegate?.menuNeedsUpdate?(tagsMenu)
                    check(
                        "finder-label-all-checkmarked-\(mode.rawValue)", labelItem.state == .on,
                        "state=\(labelItem.state.rawValue) selection=\(pane.selectedEntries.map(\.name)) folder=\(pane.currentURL.lastPathComponent)"
                    )
                    select(["source.txt", "ordinary"], menu: menu)
                    _ = window.firstResponder?.tryToPerform(action, with: labelItem)
                    tagsMenu.delegate?.menuNeedsUpdate?(tagsMenu)
                    check(
                        "finder-label-toggle-removes-both-\(mode.rawValue)",
                        labelItem.state == .off
                            && [source, second].allSatisfy { FileTags.tags(of: $0).isEmpty })
                    select([], menu: menu)
                    check(
                        "finder-label-empty-disabled-\(mode.rawValue)", !validateMenuItem(labelItem)
                    )
                } catch {
                    check(
                        "finder-label-fixture-\(mode.rawValue)", false, error.localizedDescription)
                }
                select(["source.txt"], menu: menu)
            }
            check(
                "finder-file-controls-\(mode.rawValue)",
                ["files.compress", "files.compress7z", "files.makeAlias", "view.quickLook"]
                    .allSatisfy { visible($0, in: menu) && item($0, in: menu)?.isEnabled == true }
                    && !visible("files.showOriginal", in: menu)
                    && !visible("files.showPackageContents", in: menu))
            check(
                "finder-invalid-original-refused-\(mode.rawValue)",
                !commands.perform("files.showOriginal")
                    && !commands.perform("files.showPackageContents"))
            select(["Sample.app"], menu: menu)
            check(
                "finder-package-positive-\(mode.rawValue)",
                visible("files.showPackageContents", in: menu)
                    && item("files.showPackageContents", in: menu)?.isEnabled == true)
            select(["ordinary"], menu: menu)
            check(
                "finder-directory-negative-\(mode.rawValue)",
                !visible("files.showPackageContents", in: menu))
            select(["Sample.app", "source.txt"], menu: menu)
            check(
                "finder-mixed-negative-\(mode.rawValue)",
                !visible("files.showPackageContents", in: menu)
                    && !visible("files.showOriginal", in: menu))
            select(["target-link"], menu: menu)
            check(
                "finder-link-positive-\(mode.rawValue)",
                visible("files.showOriginal", in: menu)
                    && item("files.showOriginal", in: menu)?.isEnabled == true)
            select([], menu: menu)
            check(
                "finder-empty-negative-\(mode.rawValue)",
                additions.allSatisfy { !visible($0, in: menu) })
            check(
                "finder-empty-commands-refused-\(mode.rawValue)",
                additions.allSatisfy { !commands.perform($0) })
            let rows = menu.items.filter { !$0.isHidden }
            check(
                "finder-separators-\(mode.rawValue)",
                rows.first?.isSeparatorItem != true && rows.last?.isSeparatorItem != true
                    && !zip(rows, rows.dropFirst()).contains {
                        $0.isSeparatorItem && $1.isSeparatorItem
                    })
        }
        pane.debugClickViewSwitcher(.list)
        check(
            "finder-action-list-ready",
            settle { pane.viewMode == .list && pane.debugHasEntry("source.txt") })
        guard let menu = fileMenu(in: pane.containerView) else {
            check("finder-action-menu", false)
            finish()
        }
        select(["Sample.app"], menu: menu)
        dispatch("files.showPackageContents", menu: menu)
        check(
            "finder-package-browsed-not-launched",
            settle { pane.currentURL.path == package.path && pane.debugHasEntry("Contents") })
        navigateRoot()
        select(["target-link"], menu: menu)
        dispatch("files.showOriginal", menu: menu)
        check(
            "finder-original-revealed-visible",
            settle {
                pane.currentURL.path == target.deletingLastPathComponent().path
                    && pane.selectedEntries.first?.name == "target.txt"
                    && pane.debugRowVisible("target.txt")
            })
        navigateRoot()
        select(["source.txt"], menu: menu)
        dispatch("files.makeAlias", menu: menu)
        let alias = root.appendingPathComponent("source alias.txt")
        check(
            "finder-alias-created-resolves",
            settle { fm.fileExists(atPath: alias.path) }
                && Self.resolveOriginal(of: alias)?.standardizedFileURL
                    == source.standardizedFileURL
        )
        check(
            "finder-alias-selected-visible",
            settle {
                pane.selectedEntries.first?.name == alias.lastPathComponent
                    && pane.debugRowVisible(alias.lastPathComponent)
            }, "selected=\(pane.selectedEntries.map(\.name))")
        select([alias.lastPathComponent], menu: menu)
        check(
            "finder-alias-original-offered",
            visible("files.showOriginal", in: menu)
                && item("files.showOriginal", in: menu)?.isEnabled == true)
        dispatch("files.showOriginal", menu: menu)
        check(
            "finder-alias-original-selected-visible",
            settle {
                pane.selectedEntries.first?.name == source.lastPathComponent
                    && pane.debugRowVisible(source.lastPathComponent)
            })
        for (id, ext) in [("files.compress", "zip"), ("files.compress7z", "7z")] {
            select(["source.txt"], menu: menu)
            dispatch(id, menu: menu)
            let archive = root.appendingPathComponent("source.\(ext)")
            check(
                "finder-\(ext)-created",
                settle(8) {
                    fm.fileExists(atPath: archive.path)
                        && pane.debugHasEntry(archive.lastPathComponent)
                })
            check(
                "finder-\(ext)-selected-visible",
                settle {
                    pane.selectedEntries.first?.name == archive.lastPathComponent
                        && pane.debugRowVisible(archive.lastPathComponent)
                }, "selected=\(pane.selectedEntries.map(\.name))")
            var finished = false
            var restored = false
            let output = root.appendingPathComponent("extracted-\(ext)")
            Task { @MainActor in
                do {
                    try await Archiver.extract(archive, to: output)
                    restored =
                        (try? String(
                            contentsOf: output.appendingPathComponent("source.txt"), encoding: .utf8
                        )) == "archive payload"
                } catch { print("FINDERUI: extraction error \(error)") }
                finished = true
            }
            check("finder-\(ext)-round-trip", settle(8) { finished } && restored)
        }
        check(
            "finder-source-preserved",
            (try? String(contentsOf: source, encoding: .utf8)) == "archive payload")
        // Deliver the action first, then change context before the async compressor can finish.
        if let other = (pane === leftTabs.activePane ? rightTabs : leftTabs).activePane {
            let otherFolder = target.deletingLastPathComponent()
            other.navigate(to: otherFolder)
            check("finder-race-other-listed", settle { other.debugHasEntry("target.txt") })
            other.debugSelectNames(["target.txt"])
            select(["source.txt"], menu: menu)
            let before = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            dispatch("files.compress", menu: menu)
            other.debugClickViewSwitcher(.list)
            let name = "source 2.zip"
            check(
                "finder-race-origin-archive-selected",
                settle(8) { pane.debugHasEntry(name) && pane.selectedEntries.first?.name == name },
                "existing=\(before.contains(name)) selected=\(pane.selectedEntries.map(\.name))")
            check(
                "finder-race-other-unchanged",
                activePane === other && other.currentURL.path == otherFolder.path
                    && other.selectedEntries.first?.name == "target.txt")
            pane.debugClickViewSwitcher(.list)
            select(["source.txt"], menu: menu)
            dispatch("files.compress7z", menu: menu)
            pane.navigate(to: otherFolder)
            check("finder-race-navigation-listed", settle { pane.debugHasEntry("target.txt") })
            pane.debugSelectNames(["target.txt"])
            check(
                "finder-race-navigation-archive-finished",
                settle(8) { fm.fileExists(atPath: root.appendingPathComponent("source 2.7z").path) }
            )
            _ = settle(0.4) { false }
            check(
                "finder-race-navigation-unchanged",
                pane.currentURL.path == otherFolder.path
                    && pane.selectedEntries.first?.name == "target.txt")
        } else {
            check("finder-race-other-pane", false)
        }
        navigateRoot()
        pane.showSmartResults(
            [FileEntry(name: "source.txt", isDirectory: false, size: 1, modificationDate: nil)],
            title: "Fixture smart results")
        pane.debugSelectNames(["source.txt"])
        check(
            "finder-smart-tag-selection-delivered",
            pane.isShowingSmartResults && pane.selectedEntries.count == 1)
        check(
            "finder-smart-tag-actions-disabled",
            FileTag.Color.displayOrder.allSatisfy {
                commands.command("tags.toggle.\($0.rawValue)")?.isEnabled() == false
            } && commands.command("tags.clear")?.isEnabled() == false)
        let labelValidation = NSMenuItem(
            title: "Fixture label", action: #selector(applyLabelFromMenu(_:)), keyEquivalent: "")
        check("finder-smart-label-disabled", !validateMenuItem(labelValidation))
        navigateRoot()
        let customized = FileContextMenuController()
        customized.menuOrder = ["files.compress", "files.open"]
        customized.hiddenItems = ["files.makeAlias"]
        check(
            "finder-customization-retained",
            (customized.menu.items.first?.representedObject as? String) == "files.compress"
                && !customized.menu.items.contains {
                    ($0.representedObject as? String) == "files.makeAlias"
                }
                && customized.menu.items.contains {
                    ($0.representedObject as? String) == "files.showPackageContents"
                })
        customized.hiddenItems = ["@tags"]
        check(
            "finder-hide-tags-also-hides-labels",
            !customized.menu.items.compactMap(\.submenu).contains {
                $0.items.contains { $0.representedObject is FileLabel }
            })
        // exit() does not run defer blocks; dispose the known fixture before exiting.
        try? fm.removeItem(at: root)
        finish()
    }
}
#endif
