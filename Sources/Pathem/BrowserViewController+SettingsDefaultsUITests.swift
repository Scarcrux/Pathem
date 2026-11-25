#if DEBUG
import AppKit
import CoreServices
import Darwin
import PathemEngine

@MainActor
extension BrowserViewController {
    func runSettingsDefaultsUIAutomation() -> Never {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "pathem-settings-defaults-\(UUID())")
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok))
            print("SETTINGSDEFAULTS: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
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
            try? fm.removeItem(at: base)
            let passed = checks.filter(\.1).count
            print("RESULT: \(passed == checks.count ? "PASS" : "FAIL") (\(passed)/\(checks.count))")
            exit(passed == checks.count ? 0 : 1)
        }
        guard let window = view.window, let pane = leftTabs.activePane,
            let other = rightTabs.activePane,
            let config = ConfigStore.directory()
        else {
            check("window-panes-and-config", false)
            finish()
        }
        let ordinary = base.appendingPathComponent("ordinary")
        let exact = base.appendingPathComponent("exact")
        let subtree = base.appendingPathComponent("subtree")
        let child = subtree.appendingPathComponent("child")
        let roots = [ordinary, exact, child]
        let names = ["alpha.bin", "bravo.bin", "charlie.bin"]
        let sample = ProcessInfo.processInfo.environment["PATHEM_SETTINGS_DEFAULTS_SAMPLE"] == "1"
        let datesOnly =
            ProcessInfo.processInfo.environment["PATHEM_SETTINGS_DEFAULTS_DATES_SAMPLE"] == "1"
        let startupSample =
            ProcessInfo.processInfo.environment["PATHEM_SETTINGS_DEFAULTS_STARTUP_SAMPLE"] == "1"
        func resetTimes(in root: URL) throws {
            for (index, name) in names.enumerated() {
                let access = [2000, 3000, 1000]
                let modification = [3000, 1000, 2000]
                var times = [
                    // Deliberately distinct filesystem access times are NOT
                    // Date Last Opened: that UI key uses Spotlight last-used.
                    timeval(tv_sec: time_t(1_700_000_000 + access[index]), tv_usec: 0),
                    timeval(tv_sec: time_t(1_700_000_000 + modification[index]), tv_usec: 0),
                ]
                let result = root.appendingPathComponent(name).withUnsafeFileSystemRepresentation {
                    path in
                    times.withUnsafeMutableBufferPointer { buffer in
                        path.map { utimes($0, buffer.baseAddress) } ?? -1
                    }
                }
                guard result == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                try fm.setAttributes(
                    [
                        .creationDate: Date(
                            timeIntervalSince1970: 1_700_000_000 + [1000.0, 3000.0, 2000.0][index])
                    ],
                    ofItemAtPath: root.appendingPathComponent(name).path)
            }
        }
        do {
            for root in roots {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                for (index, name) in names.enumerated() {
                    let sizes = [300, 100, 200]
                    let dates = [3000.0, 1000.0, 2000.0]
                    let url = root.appendingPathComponent(name)
                    try Data(repeating: 65, count: sizes[index]).write(to: url)
                    try fm.setAttributes(
                        [
                            .modificationDate: Date(
                                timeIntervalSince1970: 1_700_000_000 + dates[index]),
                            .creationDate: Date(
                                timeIntervalSince1970: 1_700_000_000
                                    + [1000.0, 3000.0, 2000.0][index]),
                        ],
                        ofItemAtPath: url.path)
                }
                try resetTimes(in: root)
            }
        } catch {
            check("fixture-created", false, error.localizedDescription)
            finish()
        }
        window.setContentSize(NSSize(width: 1450, height: 980))
        pane.navigate(to: exact)
        other.navigate(to: child)
        guard settle({ pane.debugEntryCount == 3 && other.debugEntryCount == 3 }) else {
            check("fixture-delivered", false)
            finish()
        }
        check("fixture-delivered", true)
        let exactFormat = ViewFormat(viewMode: .tree)
        let subtreeFormat = ViewFormat(viewMode: .column)
        folderFormats.setExact(exact.path, exactFormat)
        folderFormats.setSubtree(subtree.path, subtreeFormat)
        pane.refresh()
        other.refresh()
        check(
            "remembered-views-delivered",
            settle {
                pane.viewMode == .tree && other.viewMode == .column
                    && (pane.keyView as? NSOutlineView)?.numberOfRows == 3
                    && (other.keyView as? NSTableView)?.numberOfRows == 3
            })
        pane.debugSelectNames(["bravo.bin"])
        check("selection-input", pane.selectedEntries.map(\.name) == ["bravo.bin"])

        func descendants<T: NSView>(_ source: NSView, as type: T.Type) -> [T] {
            (source as? T).map { [$0] } ?? source.subviews.flatMap { descendants($0, as: type) }
        }
        func layoutPanel(in browser: BrowserViewController) -> (
            NSPopUpButton, NSPopUpButton, NSPopUpButton
        )? {
            if browser.settingsPanel == nil { browser.showPreferences() }
            guard let panel = browser.settingsPanel else { return nil }
            let tables = descendants(panel, as: NSTableView.self)
            guard
                let sidebar = tables.first(where: {
                    $0.numberOfRows == SettingsWindowController.Pane.allCases.count
                })
            else { return nil }
            sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            sidebar.delegate?.tableViewSelectionDidChange?(
                Notification(name: NSTableView.selectionDidChangeNotification, object: sidebar))
            browser.view.layoutSubtreeIfNeeded()
            let popups = descendants(panel, as: NSPopUpButton.self)
            guard
                let mode = popups.first(where: {
                    $0.action == NSSelectorFromString("defaultViewChanged:")
                }),
                let key = popups.first(where: {
                    $0.action == NSSelectorFromString("defaultSortChanged")
                        && $0.numberOfItems == ViewFormat.SortKey.allCases.count
                }),
                let direction = popups.first(where: {
                    $0.action == NSSelectorFromString("defaultSortChanged") && $0.numberOfItems == 2
                })
            else { return nil }
            return (mode, key, direction)
        }
        guard let controls = layoutPanel(in: self) else {
            check("mounted-layout-controls", false)
            finish()
        }
        check(
            "mounted-layout-controls",
            [controls.0, controls.1, controls.2].allSatisfy {
                $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled
            })
        func choose(_ popup: NSPopUpButton, index: Int) -> Bool {
            popup.selectItem(at: index)
            return popup.sendAction(popup.action, to: popup.target)
        }
        func positions(_ target: PaneController, _ expected: [String]) -> Bool {
            expected.count == 3
                && expected.enumerated().allSatisfy {
                    target.debugEntryPosition($0.element) == $0.offset
                }
        }
        check("empty-order-reference-is-rejected", !positions(pane, []))
        var cases: [(ViewFormat.ViewMode, ViewFormat.SortKey, Bool)] = [
            (.gallery, .size, false), (.list, .name, true),
            (.list, .size, true), (.list, .name, false),
        ]
        if !sample && !startupSample {
            cases = []
            if !datesOnly {
                for mode in ViewFormat.ViewMode.allCases {
                    for key in ViewFormat.SortKey.allCases {
                        for ascending in [true, false] { cases.append((mode, key, ascending)) }
                    }
                }
            }
            if datesOnly {
                for key in [ViewFormat.SortKey.date, .dateCreated, .dateAccessed, .dateAdded] {
                    for ascending in [true, false] { cases.append((.list, key, ascending)) }
                }
            }
        }
        func expectedOrder(_ key: ViewFormat.SortKey, ascending: Bool) throws -> (
            order: [String], distinct: Bool, allTied: Bool, evidence: String
        ) {
            // Independent oracle: read Foundation/Spotlight directly, never
            // production enrichment or ViewFormat.sorted. Ordinary fixtures
            // discriminate name/size/modified/created. Same-kind .bin files,
            // untagged files, and absent/equal provider dates instead exercise
            // stable name-ascending ties in BOTH sort directions. Synthetic
            // metadata tests separately discriminate all new sort keys.
            let metadata = try names.map { name in
                try ordinary.appendingPathComponent(name).resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                    .localizedTypeDescriptionKey, .addedToDirectoryDateKey, .tagNamesKey,
                ])
            }
            let lastOpened: [Date?] = names.map { name in
                guard key == .dateAccessed,
                    let item = MDItemCreate(
                        kCFAllocatorDefault, ordinary.appendingPathComponent(name).path as CFString)
                else { return nil }
                return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            }
            let tags = metadata.map { values in
                Array(Set((values.tagNames ?? []).filter { !$0.isEmpty })).sorted {
                    let result = $0.localizedStandardCompare($1)
                    return result == .orderedSame ? $0 < $1 : result == .orderedAscending
                }
            }
            func numericValue(_ index: Int) -> Double? {
                switch key {
                case .size: return metadata[index].fileSize.map(Double.init)
                case .date: return metadata[index].contentModificationDate?.timeIntervalSince1970
                case .dateCreated: return metadata[index].creationDate?.timeIntervalSince1970
                case .dateAccessed: return lastOpened[index]?.timeIntervalSince1970
                case .dateAdded: return metadata[index].addedToDirectoryDate?.timeIntervalSince1970
                case .name, .kind, .tags, .dimensions, .dateTaken, .camera, .duration, .artist,
                    .album, .pages, .codec, .bitRate:
                    return nil
                }
            }
            func compare(_ left: Int, _ right: Int) -> ComparisonResult {
                switch key {
                case .name: return names[left].localizedStandardCompare(names[right])
                case .kind:
                    return (metadata[left].localizedTypeDescription ?? "").localizedStandardCompare(
                        metadata[right].localizedTypeDescription ?? "")
                case .tags:
                    for (a, b) in zip(tags[left], tags[right]) {
                        let comparison = a.localizedStandardCompare(b)
                        if comparison != .orderedSame { return comparison }
                    }
                    if tags[left].count == tags[right].count { return .orderedSame }
                    return tags[left].count < tags[right].count
                        ? .orderedAscending : .orderedDescending
                case .size, .date, .dateCreated, .dateAccessed, .dateAdded:
                    let a = numericValue(left) ?? Date.distantPast.timeIntervalSince1970
                    let b = numericValue(right) ?? Date.distantPast.timeIntervalSince1970
                    if a == b { return .orderedSame }
                    return a < b ? .orderedAscending : .orderedDescending
                case .dimensions, .dateTaken, .camera, .duration, .artist, .album, .pages, .codec,
                    .bitRate:
                    return .orderedSame  // The ordinary .bin fixtures have no media fields.
                }
            }
            let distinct = names.indices.allSatisfy { left in
                names.indices.allSatisfy { right in
                    left == right || compare(left, right) != .orderedSame
                }
            }
            let allTied = names.indices.allSatisfy { compare(0, $0) == .orderedSame }
            let unknownOrUntagged: Int
            switch key {
            case .name: unknownOrUntagged = 0
            case .kind:
                unknownOrUntagged = metadata.filter { $0.localizedTypeDescription == nil }.count
            case .tags: unknownOrUntagged = tags.filter(\.isEmpty).count
            case .size, .date, .dateCreated, .dateAccessed, .dateAdded:
                unknownOrUntagged = names.indices.filter { numericValue($0) == nil }.count
            case .dimensions, .dateTaken, .camera, .duration, .artist, .album, .pages, .codec,
                .bitRate:
                unknownOrUntagged = names.count
            }
            let evidence =
                "key=\(key.rawValue) distinct=\(distinct) allTied=\(allTied) unknownOrUntagged=\(unknownOrUntagged)"
            if [.name, .size, .date, .dateCreated].contains(key),
                !distinct || unknownOrUntagged != 0
            {
                throw NSError(
                    domain: "SettingsDefaultsFixture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(key.rawValue) requires three distinct known fixture values; \(evidence)"
                    ])
            }
            let order = names.indices.sorted { left, right in
                let comparison = compare(left, right)
                if comparison == .orderedSame {
                    let byName = names[left].localizedStandardCompare(names[right])
                    return byName == .orderedSame
                        ? names[left] < names[right] : byName == .orderedAscending
                }
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }.map { names[$0] }
            return (order, distinct, allTied, evidence)
        }
        let originalTabs = leftTabs.tabCount
        for (index, item) in cases.enumerated() {
            let expected: [String]
            do {
                let reference = try expectedOrder(item.1, ascending: item.2)
                let opposite = try expectedOrder(item.1, ascending: !item.2)
                expected = reference.order
                if reference.distinct {
                    check(
                        "fixture-reference-distinct-directions-\(index)",
                        expected != opposite.order, reference.evidence)
                } else {
                    let nameAscending = names.sorted {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }
                    check(
                        "fixture-reference-tie-or-unknown-control-\(index)",
                        !reference.allTied
                            || (expected == nameAscending && opposite.order == nameAscending),
                        reference.evidence)
                }
            } catch {
                check("fixture-reference-measured-\(index)", false, error.localizedDescription)
                finish()
            }
            pane.debugSelectNames(["bravo.bin"])
            check("selection-input-\(index)", pane.selectedEntries.map(\.name) == ["bravo.bin"])
            check(
                "actions-delivered-\(index)",
                choose(controls.0, index: ViewFormat.ViewMode.allCases.firstIndex(of: item.0)!)
                    && choose(
                        controls.1, index: ViewFormat.SortKey.allCases.firstIndex(of: item.1)!)
                    && choose(controls.2, index: item.2 ? 0 : 1))
            check(
                "preferences-delivered-\(index)",
                prefs.defaultViewMode == item.0 && prefs.defaultSortKey == item.1
                    && prefs.defaultSortAscending == item.2)
            check(
                "selection-after-settings-\(index)",
                pane.selectedEntries.map(\.name) == ["bravo.bin"])
            let saved = ConfigStore.load(
                Preferences.self, from: config.appendingPathComponent("prefs.json"))
            check(
                "preferences-persisted-\(index)",
                saved?.defaultViewMode == item.0 && saved?.defaultSortKey == item.1
                    && saved?.defaultSortAscending == item.2)
            check("no-folder-override-\(index)", !folderFormats.hasRule(for: ordinary.path))
            leftTabs.openTab(at: ordinary)
            if let fresh = leftTabs.activePane {
                check(
                    "new-tab-delivered-\(index)",
                    settle { fresh !== pane && fresh.debugEntryCount == 3 })
                check(
                    "effective-default-\(index)",
                    fresh.viewMode == item.0 && fresh.format.sortKey == item.1
                        && fresh.format.ascending == item.2,
                    "view=\(fresh.viewMode.rawValue) key=\(fresh.format.sortKey.rawValue) ascending=\(fresh.format.ascending)"
                )
                check(
                    "actual-file-order-\(index)", positions(fresh, expected), "expected=\(expected)"
                )
            } else {
                check("new-tab-delivered-\(index)", false)
            }
            while leftTabs.tabCount > originalTabs { leftTabs.closeActiveTab() }
            check(
                "exact-subtree-views-retained-\(index)",
                folderFormats.format(for: exact.path) == exactFormat
                    && folderFormats.format(for: child.path) == subtreeFormat
                    && pane.viewMode == .tree && other.viewMode == .column,
                "post-tab-selection=\(pane.selectedEntries.map(\.name))")
        }
        let commandFormat = ViewFormat(
            sortKey: .date, ascending: true, showHidden: true,
            foldersFirst: false, viewMode: .icon, groupKey: .kind)
        pane.applyFormat(commandFormat)
        pane.setGroupKey(.kind)
        check(
            "reverse-command-input",
            settle { pane.viewMode == .icon && pane.format == commandFormat })
        check("reverse-command-delivered", commands.perform("view.useAsDefault"))
        check("reverse-global-format", folderFormats.defaultFormat == commandFormat)
        check(
            "reverse-preferences",
            prefs.defaultViewMode == .icon && prefs.defaultSortKey == .date
                && prefs.defaultSortAscending)
        check(
            "reverse-mounted-controls",
            controls.0.indexOfSelectedItem == ViewFormat.ViewMode.allCases.firstIndex(of: .icon)
                && controls.1.indexOfSelectedItem
                    == ViewFormat.SortKey.allCases.firstIndex(of: .date)
                && controls.2.indexOfSelectedItem == 0)
        if let toggle = settingsPanel.map({ descendants($0, as: NSButton.self) })?.first(where: {
            $0.title == L("prefs.showFullPath", "Show full path in the title bar")
        }) {
            let before = prefs.showFullPathInTitle
            toggle.performClick(nil)
            check("unrelated-setting-delivered", prefs.showFullPathInTitle != before)
            check(
                "unrelated-setting-keeps-command-default",
                prefs.defaultViewMode == .icon && prefs.defaultSortKey == .date
                    && prefs.defaultSortAscending && folderFormats.defaultFormat == commandFormat)
        } else {
            check("unrelated-setting-delivered", false)
        }
        closeSettingsPanel()
        if let reopened = layoutPanel(in: self) {
            check(
                "reopened-controls-agree",
                reopened.0.indexOfSelectedItem == ViewFormat.ViewMode.allCases.firstIndex(of: .icon)
                    && reopened.1.indexOfSelectedItem
                        == ViewFormat.SortKey.allCases.firstIndex(of: .date)
                    && reopened.2.indexOfSelectedItem == 0)
            var updatedDefault = commandFormat
            updatedDefault.ascending = false
            check("edited-default-direction-delivered", choose(reopened.2, index: 1))
            check(
                "edited-default-keeps-unrelated-fields",
                folderFormats.defaultFormat == updatedDefault)
            check(
                "edited-default-keeps-existing-rules",
                folderFormats.format(for: exact.path) == commandFormat
                    && folderFormats.format(for: child.path) == subtreeFormat
                    && pane.format == commandFormat)
            let persistedFormat = ConfigStore.load(
                FolderFormats.self, from: config.appendingPathComponent("formats.json"))
            let persistedPreferences = ConfigStore.load(
                Preferences.self, from: config.appendingPathComponent("prefs.json"))
            check(
                "edited-default-persisted",
                persistedFormat?.defaultFormat == updatedDefault
                    && persistedPreferences?.defaultViewMode == .icon
                    && persistedPreferences?.defaultSortKey == .date
                    && persistedPreferences?.defaultSortAscending == false)
            leftTabs.openTab(at: ordinary)
            if let fresh = leftTabs.activePane {
                check(
                    "edited-default-new-tab",
                    settle {
                        fresh.debugEntryCount == 3 && fresh.viewMode == .icon
                            && fresh.format == updatedDefault
                    })
                check(
                    "edited-default-new-tab-order",
                    positions(fresh, (try? expectedOrder(.date, ascending: false).order) ?? []))
            } else {
                check("edited-default-new-tab", false)
            }
            while leftTabs.tabCount > originalTabs { leftTabs.closeActiveTab() }
            check("edited-default-original-tab-restored", leftTabs.activePane === pane)
        } else {
            check("reopened-controls-agree", false)
        }
        if startupSample || (!sample && !datesOnly) {
            for scenario in ["conflicting", "prefs-only", "formats-only"] {
                var seedPrefs = Preferences.default
                seedPrefs.defaultViewMode = scenario == "prefs-only" ? .tree : .list
                seedPrefs.defaultSortKey = scenario == "prefs-only" ? .date : .name
                seedPrefs.defaultSortAscending = scenario != "prefs-only"
                seedPrefs.fontSize = 19
                let canonical = ViewFormat(
                    sortKey: .size, ascending: scenario == "formats-only", showHidden: true,
                    hiddenOverride: false, foldersFirst: false,
                    viewMode: scenario == "formats-only" ? .column : .icon, groupKey: .kind)
                let seeded = FolderFormats(
                    rules: [
                        .init(path: exact.path, scope: .exact, format: exactFormat),
                        .init(path: subtree.path, scope: .subtree, format: subtreeFormat),
                    ], defaultFormat: canonical)
                do {
                    if scenario == "formats-only" {
                        if fm.fileExists(atPath: config.appendingPathComponent("prefs.json").path) {
                            try fm.removeItem(at: config.appendingPathComponent("prefs.json"))
                        }
                    } else {
                        ConfigStore.save(seedPrefs, to: config.appendingPathComponent("prefs.json"))
                    }
                    if scenario == "prefs-only" {
                        if fm.fileExists(atPath: config.appendingPathComponent("formats.json").path)
                        {
                            try fm.removeItem(at: config.appendingPathComponent("formats.json"))
                        }
                    } else {
                        ConfigStore.save(seeded, to: config.appendingPathComponent("formats.json"))
                    }
                } catch {
                    check("startup-seed-\(scenario)", false, error.localizedDescription)
                    continue
                }
                let expectedFormat =
                    scenario == "prefs-only"
                    ? ViewFormat(sortKey: .date, ascending: false, viewMode: .tree) : canonical
                let seededPreferences = ConfigStore.load(
                    Preferences.self, from: config.appendingPathComponent("prefs.json"))
                let seededFormats = ConfigStore.load(
                    FolderFormats.self, from: config.appendingPathComponent("formats.json"))
                check(
                    "startup-seed-delivered-\(scenario)",
                    (scenario == "formats-only"
                        ? seededPreferences == nil
                        : seededPreferences?.defaultViewMode == seedPrefs.defaultViewMode
                            && seededPreferences?.fontSize == 19)
                        && (scenario == "prefs-only"
                            ? seededFormats == nil
                            : seededFormats?.defaultFormat == canonical
                                && seededFormats?.rules == seeded.rules)
                )
                let nested = BrowserViewController(start: ordinary, persistsSession: false)
                let nestedWindow = NSWindow(
                    contentRect: NSRect(x: 80, y: 80, width: 1450, height: 980),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                nestedWindow.isReleasedWhenClosed = false
                nestedWindow.contentViewController = nested
                nestedWindow.setContentSize(NSSize(width: 1450, height: 980))
                nestedWindow.makeKeyAndOrderFront(nil)
                check(
                    "startup-effective-default-\(scenario)",
                    settle {
                        nested.leftTabs.activePane?.debugEntryCount == 3
                            && nested.leftTabs.activePane?.viewMode == expectedFormat.viewMode
                            && nested.leftTabs.activePane?.format == expectedFormat
                    })
                check(
                    "startup-preferences-agree-\(scenario)",
                    nested.prefs.defaultViewMode == expectedFormat.viewMode
                        && nested.prefs.defaultSortKey == expectedFormat.sortKey
                        && nested.prefs.defaultSortAscending == expectedFormat.ascending
                        && nested.prefs.fontSize
                            == (scenario == "formats-only" ? Preferences.default.fontSize : 19)
                )
                check(
                    "startup-rules-and-fields-\(scenario)",
                    nested.folderFormats.defaultFormat == expectedFormat
                        && nested.folderFormats.rules
                            == (scenario == "prefs-only" ? [] : seeded.rules)
                )
                if let mounted = layoutPanel(in: nested) {
                    check(
                        "startup-mounted-controls-\(scenario)",
                        mounted.0.window === nestedWindow
                            && mounted.0.indexOfSelectedItem
                                == ViewFormat.ViewMode.allCases.firstIndex(
                                    of: expectedFormat.viewMode)
                            && mounted.1.indexOfSelectedItem
                                == ViewFormat.SortKey.allCases.firstIndex(
                                    of: expectedFormat.sortKey)
                            && mounted.2.indexOfSelectedItem == (expectedFormat.ascending ? 0 : 1))
                } else {
                    check("startup-mounted-controls-\(scenario)", false)
                }
                let persisted = ConfigStore.load(
                    Preferences.self, from: config.appendingPathComponent("prefs.json"))
                check(
                    "startup-reconciliation-persisted-\(scenario)",
                    persisted?.defaultViewMode == expectedFormat.viewMode
                        && persisted?.defaultSortKey == expectedFormat.sortKey
                        && persisted?.defaultSortAscending == expectedFormat.ascending)
                for side in [nested.leftTabs, nested.rightTabs] {
                    for tab in side.tabs { tab.teardown() }
                }
                nestedWindow.close()
            }
        }
        finish()
    }
}
#endif
