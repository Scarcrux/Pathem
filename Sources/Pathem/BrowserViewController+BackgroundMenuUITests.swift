#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func runBackgroundMenuUIAutomation() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok))
            FileHandle.standardOutput.write(
                Data("BACKGROUNDUI: \(ok ? "PASS" : "FAIL") \(name) \(detail)\n".utf8))
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
            let passed = checks.filter(\.1).count
            print("RESULT: \(passed == checks.count ? "PASS" : "FAIL") (\(passed)/\(checks.count))")
            exit(passed == checks.count ? 0 : 1)
        }
        guard let window = view.window, let pane = leftTabs.activePane,
            let inactive = rightTabs.activePane
        else {
            check("window-and-panes", false)
            finish()
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-background-\(UUID())")
        let otherFolder = root.appendingPathComponent("inactive")
        do {
            try fm.createDirectory(at: otherFolder, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try "alpha".write(
                to: root.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
            try "// beta".write(
                to: root.appendingPathComponent("beta.swift"), atomically: true, encoding: .utf8)
            try "other".write(
                to: otherFolder.appendingPathComponent("other.txt"), atomically: true,
                encoding: .utf8)
        } catch {
            check("fixture-created", false, error.localizedDescription)
            try? fm.removeItem(at: root)
            finish()
        }
        window.setContentSize(NSSize(width: 1200, height: 820))
        window.makeKeyAndOrderFront(nil)
        pane.navigate(to: root)
        inactive.navigate(to: otherFolder)
        check(
            "fixtures-delivered",
            settle { pane.debugEntryCount == 4 && inactive.debugEntryCount == 1 })
        func fileMenu(in view: NSView) -> NSMenu? {
            if let menu = view.menu,
                menu.items.contains(where: { $0.representedObject as? String == "files.open" })
            {
                return menu
            }
            return view.subviews.compactMap { fileMenu(in: $0) }.first
        }
        func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
            menu.items.first { $0.representedObject as? String == id }
        }
        let modes: [(ViewFormat.ViewMode, String)] = [
            (.list, "view.asList"), (.icon, "view.asIcons"), (.gallery, "view.asGallery"),
            (.column, "view.asColumn"), (.tree, "view.asTree"),
        ]
        let groups: [(ViewFormat.GroupKey, String)] = ViewFormat.GroupKey.allCases.map {
            ($0, $0.commandID)
        }
        // What every view's empty-space menu shows for a local folder on the boot volume.
        let expectedEmptySpaceIDs = [
            "files.getInfo", "files.reveal", "files.pinToFolderTree", "files.newFolder",
            "files.newFile", "files.copyPath", "files.copyName", "files.paste",
            "@view", "@arrange", "@sort", "view.options",
        ]
        let sampleOnly = ProcessInfo.processInfo.environment["PATHEM_BACKGROUND_SAMPLE_ONLY"] == "1"
        func actionEnabled(_ entry: NSMenuItem) -> Bool {
            guard let action = entry.action else { return false }
            var responder: NSResponder? = window.firstResponder
            while let current = responder, !current.responds(to: action) {
                responder = current.nextResponder
            }
            return (responder as? NSMenuItemValidation)?.validateMenuItem(entry) ?? false
        }
        func validatedMenu(for targetPane: PaneController) -> NSMenu? {
            window.makeFirstResponder(targetPane.keyView)
            guard let menu = fileMenu(in: targetPane.containerView) else { return nil }
            func validate(_ menu: NSMenu) {
                menu.delegate?.menuNeedsUpdate?(menu)
                for entry in menu.items {
                    if let submenu = entry.submenu {
                        validate(submenu)
                    }
                    guard entry.action != nil else { continue }
                    let enabled = actionEnabled(entry)
                    if sampleOnly, let id = entry.representedObject as? String,
                        id == "view.asIcons" || id == "view.arrangeKind"
                    {
                        FileHandle.standardOutput.write(
                            Data(
                                "BGVALIDATE: \(id) verdict=\(enabled) nativeEffective=\(entry.isEnabled) keyWindow=\(window.isKeyWindow) activeLeft=\(activePane === pane) supports=\(targetPane.supportsGrouping)\n"
                                    .utf8))
                    }
                }
            }
            // Headless automation has no guaranteed key window. Use this real window's
            // responder chain for the same validation/dispatch, not a substitute menu.
            validate(menu)
            return menu
        }
        func validSeparators(_ menu: NSMenu) -> Bool {
            let rows = menu.items.filter { !$0.isHidden }
            return rows.first?.isSeparatorItem != true && rows.last?.isSeparatorItem != true
                && !zip(rows, rows.dropFirst()).contains {
                    $0.isSeparatorItem && $1.isSeparatorItem
                }
        }
        func dispatch(_ entry: NSMenuItem?) -> Bool {
            guard let entry, actionEnabled(entry), !entry.isHidden, let action = entry.action else {
                return false
            }
            return window.firstResponder?.tryToPerform(action, with: entry) ?? false
        }
        func renderedKindGroups() -> Bool {
            if let table = pane.keyView as? NSTableView { return table.numberOfRows > 4 }
            if let collection = pane.keyView as? NSCollectionView {
                return collection.numberOfSections > 1
            }
            return false
        }
        func renderedFlatItems() -> Bool {
            if let table = pane.keyView as? NSTableView { return table.numberOfRows == 4 }
            if let collection = pane.keyView as? NSCollectionView {
                return collection.numberOfSections == 1
                    && collection.numberOfItems(inSection: 0) == 4
            }
            return false
        }
        inactive.debugClickViewSwitcher(.list)
        inactive.setGroupKey(ViewFormat.GroupKey.none)
        let otherMode = inactive.viewMode
        let otherGroup = inactive.groupKey
        for mode in ViewFormat.ViewMode.allCases where !sampleOnly || mode == .list {
            setActiveSide(leftTabs, pane: pane)
            pane.debugClickViewSwitcher(mode)
            check(
                "delivered-\(mode.rawValue)",
                settle { pane.viewMode == mode && pane.debugEntryCount == 4 })
            pane.debugSelectNames([])
            check("empty-selection-\(mode.rawValue)", pane.selectedEntries.isEmpty)
            guard let menu = fileMenu(in: pane.containerView) else {
                check("installed-menu-\(mode.rawValue)", false)
                continue
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            check("background-view-\(mode.rawValue)", item("@view", in: menu)?.submenu != nil)
            check("background-arrange-\(mode.rawValue)", item("@arrange", in: menu)?.submenu != nil)
            // The real empty-space menu of this view (for the list, the one its empty-area right
            // click returns), against the one shared expected list.
            let emptyMenu = (mode == .list ? pane.debugEmptySpaceMenu() : nil) ?? menu
            emptyMenu.delegate?.menuNeedsUpdate?(emptyMenu)
            let emptyIDs = emptyMenu.items.filter { !$0.isHidden && !$0.isSeparatorItem }
                .compactMap { $0.representedObject as? String }
            check(
                "empty-space-entries-\(mode.rawValue)", emptyIDs == expectedEmptySpaceIDs,
                "got=\(emptyIDs)")
            check("empty-space-separators-\(mode.rawValue)", validSeparators(emptyMenu))
            if mode != .list && mode != .icon {
                pane.setGroupKey(ViewFormat.GroupKey.none)
                let accepted = commands.perform("view.arrangeKind")
                check(
                    "unsupported-kind-refused-\(mode.rawValue)",
                    !accepted && pane.groupKey == ViewFormat.GroupKey.none,
                    "accepted=\(accepted) group=\(pane.groupKey)")
                pane.setGroupKey(ViewFormat.GroupKey.none)
            }
            guard let liveMenu = validatedMenu(for: pane),
                let viewParent = item("@view", in: liveMenu), let viewSubmenu = viewParent.submenu,
                let arrangeParent = item("@arrange", in: liveMenu),
                let arrangeSubmenu = arrangeParent.submenu
            else {
                check("live-background-submenus-\(mode.rawValue)", false)
                continue
            }
            check(
                "exact-mode-commands-\(mode.rawValue)",
                viewSubmenu.items.compactMap { $0.representedObject as? String } == modes.map(\.1))
            check(
                "exact-arrange-commands-\(mode.rawValue)",
                arrangeSubmenu.items.compactMap { $0.representedObject as? String }
                    == groups.map(\.1))
            check(
                "checked-mode-differs-\(mode.rawValue)",
                modes.allSatisfy {
                    item($0.1, in: viewSubmenu)?.state == ($0.0 == mode ? .on : .off)
                })
            check(
                "registry-actions-on-real-items-\(mode.rawValue)",
                (viewSubmenu.items + arrangeSubmenu.items).allSatisfy {
                    $0.action == #selector(performMenuCommand(_:)) && $0.target == nil
                })
            let supports = mode == .list || mode == .icon
            check(
                "arrange-capability-\(mode.rawValue)",
                pane.supportsGrouping == supports
                    && arrangeSubmenu.items.allSatisfy { actionEnabled($0) == supports },
                "supports=\(pane.supportsGrouping) verdicts=\(arrangeSubmenu.items.map { actionEnabled($0) })"
            )
            for (key, id) in (sampleOnly ? Array(groups.prefix(2)) : groups) {
                if supports {
                    check(
                        "arrange-dispatch-\(mode.rawValue)-\(key.rawValue)",
                        dispatch(item(id, in: arrangeSubmenu)))
                    check(
                        "arrange-delivered-\(mode.rawValue)-\(key.rawValue)",
                        settle { pane.groupKey == key && pane.debugEntryCount == 4 })
                    _ = validatedMenu(for: pane)
                    check(
                        "arrange-checkmarks-\(mode.rawValue)-\(key.rawValue)",
                        groups.allSatisfy {
                            item($0.1, in: arrangeSubmenu)?.state == ($0.0 == key ? .on : .off)
                        })
                    if key == .kind {
                        check(
                            "actual-kind-groups-\(mode.rawValue)", settle { renderedKindGroups() })
                    } else if key == .none {
                        check("actual-none-flat-\(mode.rawValue)", settle { renderedFlatItems() })
                    }
                } else {
                    let before = pane.groupKey
                    check(
                        "unsupported-refused-\(mode.rawValue)-\(key.rawValue)",
                        !commands.perform(id) && pane.groupKey == before)
                }
            }
            pane.setGroupKey(ViewFormat.GroupKey.none)
            check(
                "other-pane-unchanged-after-arrange-\(mode.rawValue)",
                inactive.viewMode == otherMode && inactive.groupKey == otherGroup)
            pane.debugSelectNames(["alpha.txt"])
            _ = validatedMenu(for: pane)
            emptyMenu.delegate?.menuNeedsUpdate?(emptyMenu)
            let selectedIDs = Set(
                emptyMenu.items.filter { !$0.isHidden }.compactMap {
                    $0.representedObject as? String
                })
            check(
                "selected-menu-keeps-item-entries-\(mode.rawValue)",
                ["files.open", "files.trash", "files.rename"].allSatisfy(selectedIDs.contains),
                "got=\(selectedIDs.sorted())")
            check(
                "selected-context-hides-background-\(mode.rawValue)",
                pane.selectedEntries.map(\.name) == ["alpha.txt"] && viewParent.isHidden
                    && arrangeParent.isHidden)
            pane.debugSelectNames([])
            _ = validatedMenu(for: pane)
            check(
                "clearing-restores-background-\(mode.rawValue)",
                !viewParent.isHidden && !arrangeParent.isHidden)
            check("background-separators-\(mode.rawValue)", validSeparators(liveMenu))
            pane.setContextMenuOrder(["@arrange", "files.open", "@arrange", "files.legacy"])
            guard let reordered = validatedMenu(for: pane) else {
                check("customized-menu-\(mode.rawValue)", false)
                continue
            }
            check(
                "saved-order-deduplicates-and-appends-\(mode.rawValue)",
                reordered.items.first?.representedObject as? String == "@arrange"
                    && reordered.items.filter { $0.representedObject as? String == "@arrange" }
                        .count == 1
                    && item("@view", in: reordered) != nil
                    && item("files.legacy", in: reordered) == nil)
            for hidden in ["@view", "@arrange"] {
                pane.setHiddenContextItems([hidden])
                let hiddenMenu = validatedMenu(for: pane)
                check(
                    "hide-token-\(mode.rawValue)-\(hidden)",
                    hiddenMenu.map {
                        item(hidden, in: $0) == nil && validSeparators($0)
                    } ?? false)
            }
            pane.setHiddenContextItems([])
            pane.setContextMenuOrder([])
            for (destination, id) in (sampleOnly ? Array(modes.prefix(2)) : modes) {
                pane.debugClickViewSwitcher(mode)
                check(
                    "transition-source-delivered-\(mode.rawValue)-\(destination.rawValue)",
                    settle { pane.viewMode == mode && pane.debugEntryCount == 4 })
                guard let current = validatedMenu(for: pane),
                    let submenu = item("@view", in: current)?.submenu
                else {
                    check("transition-menu-\(mode.rawValue)-\(destination.rawValue)", false)
                    continue
                }
                check(
                    "mode-dispatch-\(mode.rawValue)-\(destination.rawValue)",
                    dispatch(item(id, in: submenu)))
                check(
                    "mode-delivered-\(mode.rawValue)-\(destination.rawValue)",
                    settle {
                        pane.viewMode == destination && pane.debugEntryCount == 4
                            && activePane === pane
                    })
                if let current = validatedMenu(for: pane),
                    let submenu = item("@view", in: current)?.submenu
                {
                    check(
                        "mode-checkmarks-\(mode.rawValue)-\(destination.rawValue)",
                        modes.allSatisfy {
                            item($0.1, in: submenu)?.state == ($0.0 == destination ? .on : .off)
                        })
                } else {
                    check("transition-result-menu", false)
                }
                check(
                    "mode-other-pane-unchanged-\(mode.rawValue)-\(destination.rawValue)",
                    inactive.viewMode == otherMode && inactive.groupKey == otherGroup)
            }
        }
        // Eject on a real mounted volume: a disk image this check creates and detaches itself
        // (never a real external disk). Attached browsable, so the sidebar's own rule applies.
        func runHdiutil(_ args: [String]) -> (Int32, Data) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, Data()) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }
        let volumeName = "PathemF1-\(UUID().uuidString.prefix(8))"
        let image = root.appendingPathComponent("f1.dmg")
        var devEntry: String?
        var mountPoint: URL?
        if runHdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", volumeName, image.path])
            .0 == 0
        {
            let (status, data) = runHdiutil(["attach", "-plist", image.path])
            if status == 0,
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                let entities = plist["system-entities"] as? [[String: Any]]
            {
                for entity in entities {
                    if let mount = entity["mount-point"] as? String {
                        mountPoint = URL(fileURLWithPath: mount)
                        devEntry = entity["dev-entry"] as? String
                    }
                }
                if devEntry == nil {
                    devEntry = entities.compactMap { $0["dev-entry"] as? String }.first
                }
            }
        }
        check("eject-fixture-mounted", mountPoint != nil, "mount=\(mountPoint?.path ?? "nil")")
        if let mountPoint {
            try? "x".write(
                to: mountPoint.appendingPathComponent("inside.txt"), atomically: true,
                encoding: .utf8)
            check(
                "eject-rule-volume-root",
                SidebarController.ejectableVolume(rootedAt: mountPoint) != nil
                    && SidebarController.ejectableVolume(
                        rootedAt: mountPoint.appendingPathComponent("inside.txt")) == nil
            )
            check(
                "eject-rule-boot-volume-refused",
                SidebarController.ejectableVolume(containing: root) == nil
                    && SidebarController.ejectableVolume(
                        containing: URL(fileURLWithPath: "/")) == nil
            )
            func ejectEntry(_ menu: NSMenu?) -> NSMenuItem? {
                guard let menu else { return nil }
                menu.delegate?.menuNeedsUpdate?(menu)
                return item("files.ejectVolume", in: menu)
            }
            setActiveSide(leftTabs, pane: pane)
            for mode in ViewFormat.ViewMode.allCases {
                pane.debugClickViewSwitcher(mode)
                pane.navigate(to: mountPoint)
                check(
                    "eject-delivered-\(mode.rawValue)",
                    settle {
                        pane.viewMode == mode && pane.currentURL.path == mountPoint.path
                            && pane.debugEntryCount == 1
                    })
                pane.debugSelectNames([])
                let menu =
                    mode == .list ? pane.debugEmptySpaceMenu() : fileMenu(in: pane.containerView)
                check(
                    "eject-empty-space-shown-\(mode.rawValue)",
                    ejectEntry(menu).map { !$0.isHidden } ?? false)
                if mode == .list {
                    window.makeFirstResponder(pane.keyView)
                    check(
                        "eject-command-enabled-on-volume",
                        commands.command("files.ejectVolume")?.isEnabled() ?? false)
                    pane.debugSelectNames(["inside.txt"])
                    check(
                        "eject-hidden-for-file-selection",
                        ejectEntry(pane.debugEmptySpaceMenu()).map { $0.isHidden } ?? false)
                    pane.debugSelectNames([])
                }
            }
            // The volume's root selected from its parent: Eject shows in the file menu.
            pane.debugClickViewSwitcher(.list)
            pane.navigate(to: mountPoint.deletingLastPathComponent())
            check(
                "eject-parent-delivered",
                settle {
                    pane.currentURL.path == mountPoint.deletingLastPathComponent().path
                        && pane.debugEntryCount > 0
                })
            pane.debugSelectNames([mountPoint.lastPathComponent])
            check(
                "eject-shown-for-volume-root-selection",
                pane.selectedEntries.map(\.name) == [mountPoint.lastPathComponent]
                    && (ejectEntry(pane.debugEmptySpaceMenu()).map { !$0.isHidden } ?? false))
            pane.debugSelectNames([])
            pane.navigate(to: root)
            check("eject-restored-root", settle { pane.currentURL.path == root.path })
            if let devEntry {
                let detached = runHdiutil(["detach", "-force", devEntry]).0 == 0
                check("eject-fixture-detached", detached)
            }
        } else if let devEntry {
            _ = runHdiutil(["detach", "-force", devEntry])
        }
        if sampleOnly {
            try? fm.removeItem(at: root)
            finish()
        }
        // Switch the real active side, then route the right-hand installed menu back to
        // the same controller. These must act on the right, never the formerly active left.
        let leftMode = pane.viewMode
        let leftGroup = pane.groupKey
        setActiveSide(rightTabs, pane: inactive)
        inactive.debugSelectNames([])
        if let rightMenu = validatedMenu(for: inactive),
            let submenu = item("@view", in: rightMenu)?.submenu
        {
            check("right-side-mode-dispatch", dispatch(item("view.asIcons", in: submenu)))
            check(
                "right-side-mode-delivered",
                settle { inactive.viewMode == .icon && inactive.debugEntryCount == 1 })
            if let rightMenu = validatedMenu(for: inactive),
                let submenu = item("@arrange", in: rightMenu)?.submenu
            {
                check(
                    "right-side-arrange-dispatch", dispatch(item("view.arrangeKind", in: submenu)))
                check("right-side-arrange-delivered", inactive.groupKey == .kind)
            } else {
                check("right-side-arrange-menu", false)
            }
            check(
                "left-unchanged-after-side-switch",
                pane.viewMode == leftMode && pane.groupKey == leftGroup)
        } else {
            check("right-side-menu", false)
        }
        setActiveSide(leftTabs, pane: pane)
        try? fm.removeItem(at: root)
        finish()
    }
}
#endif
