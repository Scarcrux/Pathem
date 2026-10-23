#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func runContentConfigurationUIAutomation() -> Never {
        var checks: [(String, Bool)] = []
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pathem-content-prefs-\(UUID())")
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok))
            FileHandle.standardOutput.write(
                Data("CONTENTPREFS: \(ok ? "PASS" : "FAIL") \(name) \(detail)\n".utf8))
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
            let config = ProcessInfo.processInfo.environment["PATHEM_CONFIG_DIR"]
        else {
            check("window-panes-and-isolation", false)
            finish()
        }
        check(
            "isolated-config",
            ConfigStore.directory()?.standardizedFileURL
                == URL(fileURLWithPath: config).standardizedFileURL)
        let root = base.appendingPathComponent("root")
        let folder = root.appendingPathComponent("folder")
        let otherRoot = base.appendingPathComponent("other")
        let galleryRoot = base.appendingPathComponent("gallery-tab")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            for directory in [root, folder, otherRoot, galleryRoot] {
                try fm.createDirectory(
                    at: directory.appendingPathComponent("nested"),
                    withIntermediateDirectories: true)
                try Data("alpha".utf8).write(to: directory.appendingPathComponent("alpha.txt"))
                let file = directory.appendingPathComponent("beta.bin")
                try Data(repeating: 65, count: 1_500_000).write(to: file)
                try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            }
        } catch {
            check("fixture-created", false, error.localizedDescription)
            finish()
        }
        // The root has both the folder under test and a nested-folder negative fixture.
        window.setContentSize(NSSize(width: 1200, height: 820))
        pane.navigate(to: root)
        other.navigate(to: otherRoot)
        guard settle({ pane.debugEntryCount == 4 && other.debugEntryCount == 3 }) else {
            check("fixture-delivered", false)
            finish()
        }
        check("fixture-delivered", true)
        other.debugSelectNames(["alpha.txt"])
        check(
            "other-initial-selection-delivered",
            settle { other.selectedEntries.map(\.name) == ["alpha.txt"] },
            "selection=\(other.selectedEntries.map(\.name))")
        if ProcessInfo.processInfo.environment["PATHEM_BACKGROUND_TAB_SAMPLE"] == "1" {
            backgroundTabOwnershipChecks(
                pane: pane, root: root, freshRoot: galleryRoot, report: check)
            finish()
        }
        backgroundTabOwnershipChecks(pane: pane, root: root, freshRoot: galleryRoot, report: check)
        if ProcessInfo.processInfo.environment["PATHEM_CONTENT_PREFS_TRACE_ONLY"] == "1" {
            let stages: [(String, () -> Void)] = [
                ("table-reload", { (other.keyView as? NSTableView)?.reloadData() }),
                (
                    "row-height",
                    {
                        if let table = other.keyView as? NSTableView {
                            table.rowHeight = table.rowHeight
                        }
                    }
                ),
                ("formats", { other.setFormats(size: .binary, date: .short) }),
                (
                    "color-rules",
                    {
                        other.setColorRules(
                            ColorRules(rules: [
                                ColorRule(
                                    field: .name, op: .beginsWith, value: "alpha",
                                    colorHex: "#CC3366")
                            ]))
                    }
                ),
                (
                    "style",
                    {
                        other.applyStyle(
                            rowHeight: self.prefs.rowHeight, fontSize: self.prefs.fontSize,
                            alternatingRows: self.prefs.alternatingRows)
                    }
                ),
                (
                    "folder-sizes",
                    { other.setCalculateFolderSizes(self.prefs.calculateFolderSizes) }
                ),
                (
                    "click-behavior",
                    {
                        other.setClickBehavior(
                            singleClick: self.prefs.singleClickToOpen,
                            underlineHover: self.prefs.underlineOnHover)
                    }
                ),
                ("theme", { self.applyTheme() }),
                ("all-preferences", { self.applyPreferences() }),
            ]
            for (name, action) in stages {
                other.debugSelectNames(["alpha.txt"])
                check("trace-input-\(name)", other.selectedEntries.map(\.name) == ["alpha.txt"])
                action()
                check(
                    "trace-selection-\(name)",
                    name == "table-reload"
                        ? other.selectedEntries.isEmpty
                        : settle { other.selectedEntries.map(\.name) == ["alpha.txt"] },
                    "selection=\(other.selectedEntries.map(\.name))")
            }
            finish()
        }
        prefs.defaultViewMode = .list
        let sample = ProcessInfo.processInfo.environment["PATHEM_CONTENT_PREFS_SAMPLE_ONLY"] == "1"
        let gallerySample =
            ProcessInfo.processInfo.environment["PATHEM_CONTENT_PREFS_GALLERY_SAMPLE"] == "1"
        let rule = ColorRule(
            name: "Alpha", field: .name, op: .beginsWith, value: "alpha", colorHex: "#CC3366",
            bold: true, italic: true)
        let rules = ColorRules(rules: [rule])
        func textField(_ name: String, in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == name { return field }
            return view.subviews.compactMap { textField(name, in: $0) }.first
        }
        func nameField(_ name: String, in target: PaneController) -> NSTextField? {
            view.layoutSubtreeIfNeeded()
            if let table = target.keyView as? NSTableView {
                let column = table.tableColumns.firstIndex { $0.identifier.rawValue == "name" } ?? 0
                for row in 0..<table.numberOfRows {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true),
                        let field = textField(name, in: cell)
                    {
                        return field
                    }
                }
            } else if let collection = target.keyView as? NSCollectionView {
                for section in 0..<collection.numberOfSections {
                    for index in 0..<collection.numberOfItems(inSection: section) {
                        if let item = collection.item(at: IndexPath(item: index, section: section)),
                            let field = textField(name, in: item.view)
                        {
                            return field
                        }
                    }
                }
            }
            return nil
        }
        func colored(_ field: NSTextField?) -> Bool {
            guard let color = field?.textColor?.usingColorSpace(.sRGB) else { return false }
            return abs(color.redComponent - 0.8) < 0.01 && abs(color.greenComponent - 0.2) < 0.01
                && abs(color.blueComponent - 0.4) < 0.01
        }
        func styled(_ field: NSTextField?) -> Bool {
            guard let font = field?.font else { return false }
            return NSFontManager.shared.traits(of: font).contains([.boldFontMask, .italicFontMask])
        }
        func defaultStyle(_ field: NSTextField?) -> Bool {
            guard let field, let font = field.font else { return false }
            return !colored(field)
                && NSFontManager.shared.traits(of: font).intersection([
                    .boldFontMask, .italicFontMask,
                ]).isEmpty
        }
        func cellText(_ name: String, column id: String, in target: PaneController) -> String? {
            guard let table = target.keyView as? NSTableView,
                let field = nameField(name, in: target),
                let rowView = field.superview as? NSTableCellView,
                let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id })
            else { return nil }
            let row = table.row(for: rowView)
            guard row >= 0 else { return nil }
            table.tableColumns[column].isHidden = false
            return
                (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        func expectedSize(_ size: Preferences.SizeFormat) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = size == .binary ? .binary : .file
            return formatter.string(fromByteCount: 1_500_000)
        }
        func expectedDate(_ display: Preferences.DateDisplay) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = display == .short ? .short : .medium
            formatter.timeStyle = display == .medium ? .none : .short
            formatter.doesRelativeDateFormatting = display == .relative
            return formatter.string(from: stamp)
        }
        func middle(_ name: String?, in target: PaneController) -> Bool {
            guard let table = target.keyView as? KeyTableView, table.numberOfRows > 0 else {
                return false
            }
            window.makeFirstResponder(table)
            view.layoutSubtreeIfNeeded()
            let row: Int
            if let name {
                guard let field = nameField(name, in: target),
                    let cell = field.superview as? NSTableCellView
                else { return false }
                row = table.row(for: cell)
                guard row >= 0 else { return false }
            } else {
                row = -1
            }
            let rect =
                row >= 0
                ? table.rect(ofRow: row)
                : NSRect(
                    x: 5, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 12, width: 20,
                    height: 4)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard
                let seed = NSEvent.mouseEvent(
                    with: .otherMouseUp, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: 0), let cgEvent = seed.cgEvent
            else { return false }
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            guard let event = NSEvent(cgEvent: cgEvent) else { return false }
            let hit = table.row(at: table.convert(event.locationInWindow, from: nil))
            check(
                "middle-event-delivered-\(name ?? "empty")", event.buttonNumber == 2 && hit == row,
                "button=\(event.buttonNumber) row=\(hit) expected=\(row) window=\(event.windowNumber)"
            )
            guard event.buttonNumber == 2 && hit == row else { return false }
            table.otherMouseUp(with: event)
            return true
        }
        let modes: [ViewFormat.ViewMode] =
            gallerySample
            ? [.gallery]
            : (sample ? [.list, .icon] : [.list, .icon, .gallery, .column, .tree])
        if let namedMode = ProcessInfo.processInfo.environment["PATHEM_CONTENT_PREFS_TRACE_VIEW"],
            let mode = ViewFormat.ViewMode(rawValue: namedMode)
        {
            pane.debugClickViewSwitcher(mode)
            check(
                "trace-mode-delivered",
                settle { pane.viewMode == mode && pane.debugEntryCount == 4 })
            let actions: [(String, () -> Void)] = [
                (
                    "style",
                    {
                        pane.applyStyle(
                            rowHeight: self.prefs.rowHeight + 2, fontSize: self.prefs.fontSize + 1,
                            alternatingRows: self.prefs.alternatingRows)
                    }
                ),
                ("color-rules", { pane.setColorRules(rules) }),
                ("formats", { pane.setFormats(size: .binary, date: .short) }),
            ]
            for (name, action) in actions {
                pane.debugSelectNames(["beta.bin"])
                check(
                    "trace-input-\(mode.rawValue)-\(name)",
                    pane.selectedEntries.map(\.name) == ["beta.bin"])
                action()
                check(
                    "trace-selection-\(mode.rawValue)-\(name)",
                    pane.selectedEntries.map(\.name) == ["beta.bin"])
            }
            finish()
        }
        for mode in modes {
            pane.debugClickViewSwitcher(mode)
            check(
                "actual-mode-\(mode.rawValue)",
                settle { pane.viewMode == mode && pane.debugEntryCount == 4 })
            pane.debugSelectNames(["beta.bin"])
            check(
                "mode-selection-delivered-\(mode.rawValue)",
                pane.selectedEntries.map(\.name) == ["beta.bin"])
            prefs.colorRules = rules
            applyPreferences()
            check(
                "name-fields-\(mode.rawValue)",
                settle {
                    nameField("alpha.txt", in: pane) != nil
                        && nameField("beta.bin", in: pane) != nil
                })
            check(
                "matching-rule-\(mode.rawValue)",
                colored(nameField("alpha.txt", in: pane))
                    && styled(nameField("alpha.txt", in: pane)))
            check("unmatched-rule-\(mode.rawValue)", defaultStyle(nameField("beta.bin", in: pane)))
            var disabled = rule
            disabled.enabled = false
            prefs.colorRules = ColorRules(rules: [disabled])
            applyPreferences()
            check("disabled-rule-\(mode.rawValue)", defaultStyle(nameField("alpha.txt", in: pane)))
            prefs.colorRules = ColorRules(rules: [
                ColorRule(field: .name, op: .beginsWith, value: "alpha")
            ])
            applyPreferences()
            check("no-op-rule-\(mode.rawValue)", defaultStyle(nameField("alpha.txt", in: pane)))
            prefs.colorRules = ColorRules()
            applyPreferences()
            check("cleared-rule-\(mode.rawValue)", defaultStyle(nameField("alpha.txt", in: pane)))
            if mode == .gallery {
                let normalColor = nameField("alpha.txt", in: pane)?.textColor
                let colorOnly = ColorRule(
                    field: .name, op: .beginsWith, value: "alpha", colorHex: "#CC3366")
                pane.setColorRules(ColorRules(rules: [colorOnly]))
                let colorField = nameField("alpha.txt", in: pane)
                check(
                    "gallery-color-only",
                    colored(colorField)
                        && colorField?.font.map {
                            NSFontManager.shared.traits(of: $0).intersection([
                                .boldFontMask, .italicFontMask,
                            ]).isEmpty
                        } == true)
                pane.setColorRules(
                    ColorRules(rules: [
                        ColorRule(field: .name, op: .beginsWith, value: "alpha", bold: true)
                    ]))
                let fontField = nameField("alpha.txt", in: pane)
                check(
                    "gallery-font-only",
                    fontField != nil && fontField?.textColor == normalColor
                        && fontField?.font.map {
                            let traits = NSFontManager.shared.traits(of: $0)
                            return traits.contains(.boldFontMask)
                                && !traits.contains(.italicFontMask)
                        } == true)
                let second = ColorRule(
                    field: .name, op: .beginsWith, value: "alpha", colorHex: "#3399CC")
                let ordered = ColorRules(rules: [rule, second])
                pane.setColorRules(ordered)
                check(
                    "gallery-first-matching-rule",
                    colored(nameField("alpha.txt", in: pane))
                        && styled(nameField("alpha.txt", in: pane)))
                let sameField = nameField("alpha.txt", in: pane)
                pane.setColorRules(ordered)
                check(
                    "gallery-same-rules-no-reload",
                    sameField != nil && nameField("alpha.txt", in: pane) === sameField)
                pane.applyStyle(
                    rowHeight: prefs.rowHeight, fontSize: 23,
                    alternatingRows: prefs.alternatingRows)
                check(
                    "gallery-rules-follow-font-size",
                    colored(nameField("alpha.txt", in: pane))
                        && styled(nameField("alpha.txt", in: pane))
                        && nameField("alpha.txt", in: pane)?.font?.pointSize == 23)
                pane.setColorRules(ColorRules(rules: [disabled, second]))
                let nextColor = nameField("alpha.txt", in: pane)?.textColor?.usingColorSpace(.sRGB)
                check(
                    "gallery-disabled-first-falls-through",
                    nextColor.map {
                        abs($0.redComponent - 0.2) < 0.01
                            && abs($0.greenComponent - 0.6) < 0.01
                            && abs($0.blueComponent - 0.8) < 0.01
                    } == true && !styled(nameField("alpha.txt", in: pane)))
                pane.setColorRules(
                    ColorRules(rules: [
                        ColorRule(field: .name, op: .beginsWith, value: "alpha"), rule,
                    ]))
                check(
                    "gallery-first-no-op-blocks-later-style",
                    defaultStyle(nameField("alpha.txt", in: pane)))
                applyPreferences()
                check(
                    "gallery-font-default-restored",
                    nameField("alpha.txt", in: pane)?.font?.pointSize == CGFloat(prefs.fontSize)
                        && defaultStyle(nameField("alpha.txt", in: pane)))
            }
            check(
                "mode-selection-retained-\(mode.rawValue)",
                pane.selectedEntries.map(\.name) == ["beta.bin"])
            check(
                "other-listing-selection-\(mode.rawValue)",
                settle {
                    other.currentURL.standardizedFileURL.path == otherRoot.standardizedFileURL.path
                        && other.debugEntryCount == 3
                        && other.selectedEntries.map(\.name) == ["alpha.txt"]
                },
                "directory=\(other.currentURL.path) count=\(other.debugEntryCount) selection=\(other.selectedEntries.map(\.name))"
            )
        }
        if gallerySample {
            let originalIndex = leftTabs.activeTabIndex
            let originalCount = leftTabs.tabCount
            prefs.colorRules = rules
            applyPreferences()
            check("sample-gallery-default-command", commands.perform("view.useAsDefault"))
            check(
                "sample-gallery-default-input",
                folderFormats.defaultFormat.viewMode == .gallery
                    && !folderFormats.hasRule(for: galleryRoot.path))
            leftTabs.openTab(at: galleryRoot)
            let freshIndex = leftTabs.activeTabIndex
            if let fresh = leftTabs.activePane {
                check(
                    "sample-gallery-initial-default",
                    settle {
                        fresh !== pane && fresh.viewMode == .gallery && fresh.debugEntryCount == 3
                    }, "mode=\(fresh.viewMode.rawValue)")
                check(
                    "sample-gallery-initial-color",
                    settle { colored(nameField("alpha.txt", in: fresh)) }
                        && styled(nameField("alpha.txt", in: fresh)))
                leftTabs.selectTab(originalIndex)
                pane.debugClickViewSwitcher(.list)
                check("sample-list-default-command", commands.perform("view.useAsDefault"))
                check(
                    "sample-sticky-and-exact-inputs",
                    folderFormats.defaultFormat.viewMode == .list
                        && !folderFormats.hasRule(for: otherRoot.path)
                        && folderFormats.hasRule(for: root.path)
                        && folderFormats.format(for: root.path).viewMode == .list)
                leftTabs.selectTab(freshIndex)
                fresh.navigate(to: otherRoot)
                check(
                    "sample-gallery-navigation-stays-sticky",
                    settle {
                        fresh.currentURL.standardizedFileURL.path == otherRoot.path
                            && fresh.debugEntryCount == 3 && fresh.viewMode == .gallery
                    })
                fresh.navigate(to: root)
                check(
                    "sample-explicit-folder-overrides-sticky",
                    settle {
                        fresh.currentURL.standardizedFileURL.path == root.path
                            && fresh.debugEntryCount == 4 && fresh.viewMode == .list
                    })
            } else {
                check("sample-gallery-initial-default", false)
            }
            while leftTabs.tabCount > originalCount { leftTabs.closeActiveTab() }
            finish()
        }
        if !sample {
            pane.debugClickViewSwitcher(.tree)
            if let outline = pane.keyView as? NSOutlineView,
                let field = nameField("folder", in: pane),
                let cell = field.superview as? NSTableCellView,
                let folderNode = outline.item(atRow: outline.row(for: cell))
            {
                outline.expandItem(folderNode)
                check(
                    "expanded-tree-delivered",
                    settle { outline.numberOfRows == 7 && outline.isItemExpanded(folderNode) })
                if let field = nameField("beta.bin", in: pane),
                    let cell = field.superview as? NSTableCellView
                {
                    outline.selectRowIndexes(
                        IndexSet(integer: outline.row(for: cell)), byExtendingSelection: false)
                }
                check(
                    "expanded-child-selection-input",
                    pane.selectedEntries.count == 1
                        && pane.selectedEntries.first?.location == folder.path)
                pane.setColorRules(rules)
                pane.applyStyle(
                    rowHeight: prefs.rowHeight + 2, fontSize: prefs.fontSize + 1,
                    alternatingRows: prefs.alternatingRows)
                check(
                    "expanded-child-selection-retained",
                    outline.isItemExpanded(folderNode) && outline.numberOfRows == 7
                        && pane.selectedEntries.count == 1
                        && pane.selectedEntries.first?.location == folder.path)
            } else {
                check("expanded-tree-delivered", false)
            }
            pane.debugSelectNames([])
            pane.debugClickViewSwitcher(.column)
            check(
                "column-root-delivered",
                settle { (pane.keyView as? NSTableView)?.numberOfRows == 4 })
            if let table = pane.keyView as? NSTableView,
                let field = nameField("folder", in: pane),
                let cell = field.superview as? NSTableCellView
            {
                pane.debugColumnDrill(row: table.row(for: cell))
            }
            func tables(in source: NSView) -> [NSTableView] {
                (source as? NSTableView).map { [$0] } ?? source.subviews.flatMap { tables(in: $0) }
            }
            check(
                "drilled-column-mounted",
                settle { tables(in: pane.containerView).contains { $0.numberOfRows == 3 } })
            if let child = tables(in: pane.containerView).first(where: { $0.numberOfRows == 3 }) {
                for row in 0..<child.numberOfRows {
                    if let cell = child.view(atColumn: 0, row: row, makeIfNecessary: true),
                        textField("alpha.txt", in: cell) != nil
                    {
                        pane.debugColumnDrill(row: row, column: 1)
                        break
                    }
                }
            }
            check(
                "drilled-column-delivered",
                settle {
                    pane.currentURL.standardizedFileURL.path == folder.path
                        && (pane.keyView as? NSTableView)?.numberOfRows == 3
                })
            pane.debugSelectNames(["alpha.txt"])
            let columnKey = pane.keyView
            let columnOrigin = pane.contentClipView.bounds.origin
            check(
                "drilled-column-selection-input", pane.selectedEntries.map(\.name) == ["alpha.txt"])
            pane.setColorRules(
                ColorRules(rules: [
                    ColorRule(field: .name, op: .beginsWith, value: "alpha", colorHex: "#3399CC")
                ]))
            check(
                "column-appearance-is-not-redrill",
                pane.currentURL.standardizedFileURL.path == folder.path
                    && pane.keyView === columnKey
                    && pane.selectedEntries.map(\.name) == ["alpha.txt"]
                    && abs(pane.contentClipView.bounds.origin.x - columnOrigin.x) < 1)
            pane.navigate(to: otherRoot)
            pane.navigate(to: root)
            check(
                "root-restored-after-hierarchy",
                settle {
                    pane.currentURL.standardizedFileURL.path == root.path
                        && pane.debugEntryCount == 4
                })
        }
        pane.debugClickViewSwitcher(.list)
        check(
            "list-return-delivered", settle { pane.viewMode == .list && pane.debugEntryCount == 4 })
        check("size-control-discriminates", expectedSize(.decimal) != expectedSize(.binary))
        check(
            "date-control-discriminates",
            Set(Preferences.DateDisplay.allCases.map(expectedDate)).count == 3)
        for size in Preferences.SizeFormat.allCases {
            for date in Preferences.DateDisplay.allCases {
                prefs.sizeFormat = size
                prefs.dateDisplay = date
                applyPreferences()
                check(
                    "size-\(size.rawValue)-\(date.rawValue)",
                    cellText("beta.bin", column: "size", in: pane) == expectedSize(size),
                    "actual=\(cellText("beta.bin", column: "size", in: pane) ?? "missing") expected=\(expectedSize(size))"
                )
                check(
                    "date-\(size.rawValue)-\(date.rawValue)",
                    cellText("beta.bin", column: "date", in: pane) == expectedDate(date))
            }
        }
        prefs.colorRules = rules
        prefs.sizeFormat = .binary
        prefs.dateDisplay = .short
        prefs.middleClickOpensNewTab = false
        prefs.fontSize = 17
        prefs.density = .comfortable
        prefs.hiddenContextItems = ["@view"]
        prefs.contextMenuOrder = ["@arrange", "files.open"]
        applyPreferences()
        let originalTabs = leftTabs.tabCount
        let otherTabs = rightTabs.tabCount
        check("disabled-middle-target-ready", middle("folder", in: pane))
        check(
            "disabled-middle-no-tab",
            leftTabs.tabCount == originalTabs && rightTabs.tabCount == otherTabs)
        prefs.middleClickOpensNewTab = true
        applyPreferences()
        check("file-middle-target-ready", middle("alpha.txt", in: pane))
        check("file-middle-no-tab", leftTabs.tabCount == originalTabs)
        check("empty-middle-target-ready", middle(nil, in: pane))
        check("empty-middle-no-tab", leftTabs.tabCount == originalTabs)
        check("enabled-middle-target-ready", middle("folder", in: pane))
        let opened = settle {
            leftTabs.tabCount == originalTabs + 1
                && leftTabs.activePane?.currentURL.standardizedFileURL.path
                    == folder.standardizedFileURL.path
        }
        check(
            "enabled-folder-real-tab",
            opened && rightTabs.tabCount == otherTabs
                && pane.currentURL.standardizedFileURL.path == root.standardizedFileURL.path,
            "leftTabs=\(leftTabs.tabCount) rightTabs=\(rightTabs.tabCount) target=\(leftTabs.activePane?.currentURL.path ?? "missing")"
        )
        while leftTabs.tabCount > originalTabs { leftTabs.closeActiveTab() }
        check(
            "original-tab-restored",
            leftTabs.activePane === pane && leftTabs.tabCount == originalTabs)
        let stored = ConfigStore.load(Preferences.self, from: Self.preferencesURL)
        check(
            "actual-preferences-persisted",
            stored?.colorRules == rules && stored?.sizeFormat == .binary
                && stored?.dateDisplay == .short && stored?.middleClickOpensNewTab == true)
        if !sample {
            for mode in modes {
                pane.debugClickViewSwitcher(mode)
                check(
                    "retained-mode-\(mode.rawValue)",
                    settle { pane.viewMode == mode && pane.debugEntryCount == 4 })
                check(
                    "retained-color-\(mode.rawValue)",
                    settle { nameField("alpha.txt", in: pane) != nil }
                        && colored(nameField("alpha.txt", in: pane))
                )
            }
            pane.debugClickViewSwitcher(.list)
            check(
                "retained-list-format",
                settle {
                    cellText("beta.bin", column: "size", in: pane) == expectedSize(.binary)
                        && cellText("beta.bin", column: "date", in: pane) == expectedDate(.short)
                })
            leftTabs.openTab(at: root)
            if let fresh = leftTabs.activePane {
                check(
                    "new-tab-delivered",
                    settle {
                        fresh !== pane && fresh.viewMode == .list && fresh.debugEntryCount == 4
                    })
                check(
                    "new-tab-color",
                    colored(nameField("alpha.txt", in: fresh))
                        && styled(nameField("alpha.txt", in: fresh)))
                check(
                    "new-tab-style",
                    abs(
                        (nameField("alpha.txt", in: fresh)?.font?.pointSize ?? 0)
                            - CGFloat(prefs.fontSize)) < 0.01
                        && (fresh.keyView as? NSTableView)?.rowHeight == CGFloat(prefs.rowHeight))
                check(
                    "new-tab-format",
                    cellText("beta.bin", column: "size", in: fresh) == expectedSize(.binary)
                        && cellText("beta.bin", column: "date", in: fresh) == expectedDate(.short))
                let menu = (fresh.keyView as? NSTableView)?.menu
                check(
                    "new-tab-menu-hidden",
                    menu?.items.contains(where: { $0.representedObject as? String == "@view" })
                        == false)
                check(
                    "new-tab-menu-order",
                    menu?.items.first?.representedObject as? String == "@arrange")
                check("new-tab-middle-target-ready", middle("folder", in: fresh))
                check(
                    "new-tab-middle-preference",
                    settle {
                        leftTabs.tabCount == originalTabs + 2
                            && leftTabs.activePane?.currentURL.standardizedFileURL.path
                                == folder.standardizedFileURL.path
                    })
            } else {
                check("new-tab-delivered", false)
            }
            while leftTabs.tabCount > originalTabs { leftTabs.closeActiveTab() }
            pane.debugClickViewSwitcher(.gallery)
            check(
                "new-gallery-default-view-delivered",
                settle { pane.viewMode == .gallery && pane.debugEntryCount == 4 })
            check("new-gallery-default-action", commands.perform("view.useAsDefault"))
            check(
                "new-gallery-folder-has-no-saved-format",
                !folderFormats.hasRule(for: galleryRoot.path)
                    && folderFormats.defaultFormat.viewMode == .gallery)
            leftTabs.openTab(at: galleryRoot)
            if let fresh = leftTabs.activePane {
                check(
                    "new-gallery-tab-delivered",
                    settle {
                        fresh !== pane && fresh.viewMode == .gallery && fresh.debugEntryCount == 3
                            && nameField("alpha.txt", in: fresh) != nil
                    }, "mode=\(fresh.viewMode.rawValue) count=\(fresh.debugEntryCount)")
                check(
                    "new-gallery-tab-inherits-color-and-font",
                    colored(nameField("alpha.txt", in: fresh))
                        && styled(nameField("alpha.txt", in: fresh))
                        && nameField("alpha.txt", in: fresh)?.font?.pointSize
                            == CGFloat(prefs.fontSize)
                )
                fresh.debugSelectNames(["beta.bin"])
                fresh.setColorRules(ColorRules())
                check(
                    "new-gallery-tab-override-is-isolated",
                    fresh.selectedEntries.map(\.name) == ["beta.bin"]
                        && defaultStyle(nameField("alpha.txt", in: fresh))
                        && colored(nameField("alpha.txt", in: pane)))
            } else {
                check("new-gallery-tab-delivered", false)
            }
            while leftTabs.tabCount > originalTabs { leftTabs.closeActiveTab() }
            check(
                "all-original-tabs-restored",
                leftTabs.activePane === pane && rightTabs.tabCount == otherTabs)
            for mode in [ViewFormat.ViewMode.list, .icon, .column, .tree] {
                let activationStart = leftTabs.debugActivationReceipts.count
                pane.debugClickViewSwitcher(mode)
                check(
                    "default-source-delivered-\(mode.rawValue)",
                    settle { pane.viewMode == mode && pane.debugEntryCount == 4 })
                check(
                    "default-command-delivered-\(mode.rawValue)",
                    commands.perform("view.useAsDefault")
                        && folderFormats.defaultFormat.viewMode == mode
                        && !folderFormats.hasRule(for: galleryRoot.path))
                leftTabs.openTab(at: galleryRoot)
                if let fresh = leftTabs.activePane {
                    check(
                        "default-new-tab-delivered-\(mode.rawValue)",
                        settle {
                            fresh !== pane && fresh.viewMode == mode && fresh.debugEntryCount == 3
                                && nameField("alpha.txt", in: fresh) != nil
                        }, "mode=\(fresh.viewMode.rawValue)")
                    check(
                        "default-new-tab-color-\(mode.rawValue)",
                        colored(nameField("alpha.txt", in: fresh))
                            && styled(nameField("alpha.txt", in: fresh)))
                } else {
                    check("default-new-tab-delivered-\(mode.rawValue)", false)
                }
                while leftTabs.tabCount > originalTabs { leftTabs.closeActiveTab() }
                check(
                    "default-original-tab-restored-\(mode.rawValue)",
                    leftTabs.activePane === pane && rightTabs.tabCount == otherTabs,
                    "active=\(leftTabs.activeTabIndex) count=\(leftTabs.tabCount) originalExists=\(leftTabs.tabs.contains { $0 === pane }) originalDisplayed=\(pane.containerView.window === window) receipts=\(leftTabs.debugActivationReceipts.dropFirst(activationStart).map { "source=\($0.sourceIndex),previous=\($0.previousIndex),displayed=\($0.sourceDisplayed)" })"
                )
            }
            let otherBefore = nameField("alpha.txt", in: other)?.textColor
            pane.setColorRules(ColorRules())
            check(
                "per-pane-override",
                defaultStyle(nameField("alpha.txt", in: pane))
                    && colored(nameField("alpha.txt", in: other))
                    && nameField("alpha.txt", in: other)?.textColor == otherBefore)
        }
        // Display-only changes must preserve both intentional selection and scrolling.
        let longRoot = base.appendingPathComponent("long")
        do {
            try fm.createDirectory(at: longRoot, withIntermediateDirectories: true)
            for index in 0..<150 {
                try Data([65]).write(
                    to: longRoot.appendingPathComponent(String(format: "item-%03d.txt", index)))
            }
        } catch {
            check("viewport-fixture-created", false, error.localizedDescription)
            finish()
        }
        pane.debugClickViewSwitcher(.list)
        pane.navigate(to: longRoot)
        guard
            settle({
                pane.debugEntryCount == 150 && (pane.keyView as? NSTableView)?.numberOfRows == 150
            }),
            let table = pane.keyView as? NSTableView
        else {
            check("viewport-fixture-delivered", false)
            finish()
        }
        check("viewport-fixture-delivered", true)
        pane.debugSelectNames(["item-092.txt"])
        table.scrollRowToVisible(92)
        view.layoutSubtreeIfNeeded()
        check(
            "viewport-visible-selection-input",
            table.selectedRow == 92 && table.rect(ofRow: 92).intersects(table.visibleRect)
                && pane.contentClipView.bounds.origin.y > 0)
        pane.applyStyle(
            rowHeight: prefs.rowHeight + 6, fontSize: prefs.fontSize + 2,
            alternatingRows: prefs.alternatingRows)
        check(
            "density-keeps-visible-selection",
            pane.selectedEntries.map(\.name) == ["item-092.txt"]
                && table.rect(ofRow: 92).intersects(table.visibleRect))
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        table.scrollRowToVisible(110)
        view.layoutSubtreeIfNeeded()
        let awayOrigin = pane.contentClipView.bounds.origin
        check(
            "viewport-scrolled-away-input",
            table.selectedRow == 5 && !table.rect(ofRow: 5).intersects(table.visibleRect)
                && awayOrigin.y > 0)
        pane.setColorRules(
            ColorRules(rules: [
                ColorRule(field: .name, op: .beginsWith, value: "item", colorHex: "#CC3366")
            ]))
        check(
            "color-reload-does-not-yank-offscreen-selection",
            table.selectedRow == 5 && abs(pane.contentClipView.bounds.origin.y - awayOrigin.y) < 1
                && !table.rect(ofRow: 5).intersects(table.visibleRect))
        table.deselectAll(nil)
        let emptyOrigin = pane.contentClipView.bounds.origin
        pane.setFormats(size: .binary, date: .medium)
        check(
            "empty-selection-keeps-scroll",
            table.selectedRowIndexes.isEmpty
                && abs(pane.contentClipView.bounds.origin.y - emptyOrigin.y) < 1)
        table.selectRowIndexes(IndexSet([80, 82, 85]), byExtendingSelection: false)
        table.scrollRowToVisible(82)
        let selectedNames = Set(pane.selectedEntries.map(\.name))
        pane.setColorRules(ColorRules())
        check(
            "multiple-selection-retained",
            selectedNames.count == 3 && Set(pane.selectedEntries.map(\.name)) == selectedNames)
        pane.setGroupKey(.kind)
        check("grouped-viewport-fixture", settle { table.numberOfRows == 151 })
        pane.debugSelectNames(["item-092.txt"])
        let groupedRow = table.selectedRow
        pane.setFormats(size: .decimal, date: .relative)
        check(
            "group-header-indexes-retained",
            groupedRow == 93 && table.selectedRow == groupedRow
                && pane.selectedEntries.map(\.name) == ["item-092.txt"])
        for mode in [ViewFormat.ViewMode.icon, .gallery] {
            pane.debugClickViewSwitcher(mode)
            guard
                settle({
                    guard let delivered = pane.keyView as? NSCollectionView,
                        delivered.numberOfSections > 0
                    else { return false }
                    return pane.viewMode == mode && pane.debugEntryCount == 150
                        && delivered.numberOfItems(inSection: 0) == 150
                }),
                let collection = pane.keyView as? NSCollectionView
            else {
                check("collection-viewport-\(mode.rawValue)", false)
                continue
            }
            let selectedPath = IndexPath(item: 92, section: 0)
            let awayPath = IndexPath(item: 5, section: 0)
            let scrollPath = IndexPath(item: 110, section: 0)
            collection.selectionIndexPaths = [selectedPath]
            collection.scrollToItems(
                at: [selectedPath],
                scrollPosition: mode == .gallery ? .centeredHorizontally : .centeredVertically)
            view.layoutSubtreeIfNeeded()
            check(
                "collection-visible-input-\(mode.rawValue)",
                collection.layoutAttributesForItem(at: selectedPath)?.frame.intersects(
                    collection.visibleRect) == true
                    && pane.selectedEntries.map(\.name) == ["item-092.txt"])
            pane.applyStyle(
                rowHeight: prefs.rowHeight, fontSize: prefs.fontSize + 2,
                alternatingRows: prefs.alternatingRows)
            check(
                "collection-visible-retained-\(mode.rawValue)",
                collection.selectionIndexPaths == [selectedPath]
                    && collection.layoutAttributesForItem(at: selectedPath)?.frame.intersects(
                        collection.visibleRect) == true
            )
            let collectionRules = ColorRules(rules: [
                ColorRule(
                    field: .name, op: .beginsWith, value: "item", colorHex: "#CC3366",
                    bold: true, italic: true)
            ])
            pane.setColorRules(collectionRules)
            check(
                "collection-visible-color-retained-\(mode.rawValue)",
                collection.selectionIndexPaths == [selectedPath]
                    && collection.layoutAttributesForItem(at: selectedPath)?.frame.intersects(
                        collection.visibleRect) == true
                    && colored(nameField("item-092.txt", in: pane))
                    && styled(nameField("item-092.txt", in: pane)))
            collection.selectionIndexPaths = [awayPath]
            collection.scrollToItems(
                at: [scrollPath],
                scrollPosition: mode == .gallery ? .centeredHorizontally : .centeredVertically)
            view.layoutSubtreeIfNeeded()
            let away = pane.contentClipView.bounds.origin
            check(
                "collection-away-input-\(mode.rawValue)",
                collection.layoutAttributesForItem(at: awayPath)?.frame.intersects(
                    collection.visibleRect) == false && (away.x > 0 || away.y > 0))
            pane.applyStyle(
                rowHeight: prefs.rowHeight, fontSize: prefs.fontSize + 3,
                alternatingRows: prefs.alternatingRows)
            check(
                "collection-away-retained-\(mode.rawValue)",
                collection.selectionIndexPaths == [awayPath]
                    && abs(pane.contentClipView.bounds.origin.x - away.x) < 1
                    && abs(pane.contentClipView.bounds.origin.y - away.y) < 1
                    && collection.layoutAttributesForItem(at: awayPath)?.frame.intersects(
                        collection.visibleRect) == false
            )
            pane.setColorRules(ColorRules())
            check(
                "collection-away-color-clear-retained-\(mode.rawValue)",
                collection.selectionIndexPaths == [awayPath]
                    && abs(pane.contentClipView.bounds.origin.x - away.x) < 1
                    && abs(pane.contentClipView.bounds.origin.y - away.y) < 1
                    && collection.layoutAttributesForItem(at: awayPath)?.frame.intersects(
                        collection.visibleRect) == false
                    && defaultStyle(nameField("item-110.txt", in: pane)))
            collection.selectionIndexPaths = []
            let empty = pane.contentClipView.bounds.origin
            pane.applyStyle(
                rowHeight: prefs.rowHeight, fontSize: prefs.fontSize + 4,
                alternatingRows: prefs.alternatingRows)
            check(
                "collection-empty-keeps-scroll-\(mode.rawValue)",
                collection.selectionIndexPaths.isEmpty
                    && abs(pane.contentClipView.bounds.origin.x - empty.x) < 1
                    && abs(pane.contentClipView.bounds.origin.y - empty.y) < 1)
            pane.setColorRules(collectionRules)
            check(
                "collection-empty-color-keeps-scroll-\(mode.rawValue)",
                collection.selectionIndexPaths.isEmpty
                    && abs(pane.contentClipView.bounds.origin.x - empty.x) < 1
                    && abs(pane.contentClipView.bounds.origin.y - empty.y) < 1
                    && colored(nameField("item-110.txt", in: pane)))
            let multiple: Set<IndexPath> = [scrollPath, IndexPath(item: 111, section: 0)]
            collection.selectionIndexPaths = multiple
            check(
                "collection-multiple-color-input-\(mode.rawValue)",
                collection.selectionIndexPaths == multiple
                    && Set(pane.selectedEntries.map(\.name)) == ["item-110.txt", "item-111.txt"])
            pane.setColorRules(ColorRules())
            check(
                "collection-multiple-color-retained-\(mode.rawValue)",
                collection.selectionIndexPaths == multiple
                    && Set(pane.selectedEntries.map(\.name)) == ["item-110.txt", "item-111.txt"]
                    && abs(pane.contentClipView.bounds.origin.x - empty.x) < 1
                    && abs(pane.contentClipView.bounds.origin.y - empty.y) < 1
                    && defaultStyle(nameField("item-110.txt", in: pane)))
        }
        finish()
    }

    /// The refresh is real content delivery, not an injected onBecomeActive callback.
    private func backgroundTabOwnershipChecks(
        pane: PaneController, root: URL, freshRoot: URL,
        report: (String, Bool, String) -> Void
    ) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            report("tab-owner-" + name, ok, detail)
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        let originalIndex = leftTabs.activeTabIndex
        let originalCount = leftTabs.tabCount
        for mode in [ViewFormat.ViewMode.list, .column] {
            pane.debugClickViewSwitcher(mode)
            let modeDelivered = settle {
                pane.viewMode == mode && pane.debugEntryCount == 4
                    && pane.currentURL.standardizedFileURL == root.standardizedFileURL
                    && pane.containerView.window === view.window && leftTabs.activePane === pane
            }
            check("mode-delivered-" + mode.rawValue, modeDelivered)
            guard modeDelivered else { return }
            pane.debugSelectNames(["alpha.txt"])
            let selectionDelivered = pane.selectedEntries.map(\.name) == ["alpha.txt"]
            check("selection-delivered-" + mode.rawValue, selectionDelivered)
            guard selectionDelivered else { return }
            let displayedReceipt = leftTabs.debugActivationReceipts.count
            pane.debugReloadContentInPlace()
            if mode == .column {
                check(
                    "displayed-column-refresh-no-activation",
                    leftTabs.debugActivationReceipts.dropFirst(displayedReceipt).isEmpty)
                // Refresh no longer impersonates focus. Test the captured-source gate
                // explicitly, with a positive source that must activate the visible side.
                let controlReceipt = leftTabs.debugActivationReceipts.count
                if let other = rightTabs.activePane { setActiveSide(rightTabs, pane: other) }
                pane.onBecomeActive?()
                check(
                    "displayed-explicit-activation-control",
                    activeSide === leftTabs && leftTabs.activePane === pane
                        && leftTabs.debugActivationReceipts.dropFirst(controlReceipt).contains {
                            $0.sourceIndex == originalIndex && $0.sourceDisplayed
                        })
            }
            check(
                "displayed-refresh-control-" + mode.rawValue,
                leftTabs.activePane === pane && pane.selectedEntries.map(\.name) == ["alpha.txt"]
                    && pane.containerView.window === view.window)
            leftTabs.openTab(at: freshRoot)
            guard let fresh = leftTabs.activePane, fresh !== pane else {
                check("new-tab-created-" + mode.rawValue, false)
                return
            }
            let foregroundDelivered = settle {
                fresh.currentURL.standardizedFileURL == freshRoot.standardizedFileURL
                    && fresh.debugEntryCount == 3 && leftTabs.activePane === fresh
                    && fresh.containerView.window === view.window
                    && pane.containerView.superview == nil
                    && leftTabs.tabCount == originalCount + 1
            }
            check("foreground-delivered-" + mode.rawValue, foregroundDelivered)
            guard foregroundDelivered else { return }
            let foregroundIndex = leftTabs.activeTabIndex
            let hiddenReceipt = leftTabs.debugActivationReceipts.count
            pane.debugReloadContentInPlace()
            let hidden = leftTabs.debugActivationReceipts.dropFirst(hiddenReceipt)
            if mode == .column {
                check(
                    "hidden-column-refresh-no-activation", hidden.isEmpty)
                let controlReceipt = leftTabs.debugActivationReceipts.count
                pane.onBecomeActive?()
                check(
                    "hidden-explicit-activation-reaches-gate",
                    leftTabs.debugActivationReceipts.dropFirst(controlReceipt).contains {
                        $0.sourceIndex == originalIndex && !$0.sourceDisplayed
                            && $0.previousIndex == foregroundIndex
                    },
                    "receipts=\(hidden.map { "source=\($0.sourceIndex),previous=\($0.previousIndex),displayed=\($0.sourceDisplayed)" })"
                )
            } else {
                check("hidden-list-no-activation-control", hidden.isEmpty)
            }
            check(
                "hidden-refresh-preserves-active-" + mode.rawValue,
                leftTabs.activePane === fresh && leftTabs.activeTabIndex == foregroundIndex,
                "active=\(leftTabs.activeTabIndex) expected=\(foregroundIndex)")
            check(
                "hidden-refresh-keeps-displayed-" + mode.rawValue,
                fresh.containerView.window === view.window && pane.containerView.superview == nil)
            let marker = root.appendingPathComponent("watcher-" + mode.rawValue + ".txt")
            let watcherReceipt = leftTabs.debugActivationReceipts.count
            do {
                try Data("watcher fixture".utf8).write(to: marker)
            } catch {
                check("watcher-fixture-written-" + mode.rawValue, false, error.localizedDescription)
                return
            }
            check(
                "watcher-listing-delivered-" + mode.rawValue,
                settle { pane.debugHasEntry(marker.lastPathComponent) })
            if mode == .column {
                check(
                    "watcher-hidden-column-no-activation",
                    leftTabs.debugActivationReceipts.dropFirst(watcherReceipt).isEmpty)
            }
            check(
                "watcher-preserves-active-" + mode.rawValue,
                leftTabs.activePane === fresh && fresh.containerView.window === view.window,
                "active=\(leftTabs.activeTabIndex) expected=\(foregroundIndex)")
            try? FileManager.default.removeItem(at: marker)
            check("watcher-fixture-removed-" + mode.rawValue, settle { pane.debugEntryCount == 4 })
            if let other = rightTabs.activePane {
                other.keyView.window?.makeFirstResponder(other.keyView)
                check("other-side-focus-delivered-" + mode.rawValue, activeSide === rightTabs)
                fresh.keyView.window?.makeFirstResponder(fresh.keyView)
                check(
                    "foreground-focus-restored-" + mode.rawValue,
                    activeSide === leftTabs && leftTabs.activePane === fresh)
            }
            leftTabs.closeActiveTab()
            check(
                "close-targets-visible-tab-" + mode.rawValue,
                leftTabs.activePane === pane && leftTabs.tabs.contains { $0 === pane }
                    && !leftTabs.tabs.contains { $0 === fresh }
                    && pane.containerView.window === view.window,
                "originalExists=\(leftTabs.tabs.contains { $0 === pane }) freshExists=\(leftTabs.tabs.contains { $0 === fresh })"
            )
        }
    }
}
#endif
