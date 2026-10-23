#if DEBUG
import AppKit
import Darwin
import PathemEngine

extension BrowserViewController {
    func checkViewOptions(root: URL, check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool) {
        let controller = ViewOptionsController(
            format: .default, effective: .defaults(.default), folderName: "Fixture")
        check(
            "view-options-default-relative-control",
            controller.relative.state == .on && controller.format.options.dateDisplay == .relative)
        controller.alert.layout()
        let inspector = controller.alert.window
        inspector.makeKeyAndOrderFront(nil)
        inspector.contentView?.layoutSubtreeIfNeeded()
        if let scroll = controller.alert.accessoryView as? NSScrollView,
            let document = scroll.documentView
        {
            check(
                "view-options-native-scroll-layout",
                document.frame.height > scroll.contentSize.height && document.frame.width > 400
                    && document.frame.width <= scroll.frame.width)
            check(
                "view-options-native-relative-visible",
                controller.relative.convert(controller.relative.bounds, to: scroll.contentView)
                    .intersects(scroll.contentView.bounds))
        } else {
            check("view-options-native-scroll-layout", false)
        }
        inspector.orderOut(nil)
        controller.mode.selectItem(at: 3)
        controller.updateCapabilities()
        check(
            "view-options-column-capabilities-not-silent-noops",
            !controller.group.isEnabled && !controller.spacing.isEnabled
                && controller.relative.isEnabled)
        controller.mode.selectItem(at: 0)
        controller.updateCapabilities()
        controller.relative.state = .off
        controller.dates.selectItem(at: 0)
        controller.font.selectItem(withTitle: "18")
        controller.listIcons.selectItem(withTitle: "32")
        controller.position.selectItem(at: 1)
        check(
            "view-options-real-control-delivery",
            controller.format.options.dateDisplay == .short
                && controller.format.options.fontSize == 18
                && controller.format.options.listIconSize == 32
                && controller.format.options.labelPosition == .right)
        let list = FileListController()
        list.directoryURL = URL(fileURLWithPath: "/fixture")
        var options = FolderViewOptions.defaults(.default)
        options.columns = [
            "name", "date", "dateAdded", "tags", "cloudStatus", "sharedBy", "modifiedBy", "version",
        ]
        options.listIconSize = 32
        list.setViewOptions(options)
        list.setFormats(size: .decimal, date: .relative)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        list.setEntries([
            FileEntry(name: "today.txt", isDirectory: false, size: 1, modificationDate: now),
            FileEntry(
                name: "yesterday.txt", isDirectory: false, size: 1, modificationDate: yesterday),
        ])
        let table = list.keyView as! NSTableView
        func redPixels(_ icon: NSImageView) -> Int {
            let size = Int(icon.bounds.width)
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            icon.bounds.fill(using: .copy)
            icon.cell?.draw(withFrame: icon.bounds, in: icon)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return (0..<size).reduce(0) { count, y in
                count
                    + (0..<size).filter { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        else { return false }
                        return color.alphaComponent > 0.8 && color.redComponent > 0.8
                            && color.greenComponent < 0.2
                    }.count
            }
        }
        for size in [48, 64] {
            options.listIconSize = size
            list.setViewOptions(options)
            let nameColumn = table.tableColumns.first { $0.identifier.rawValue == "name" }!
            let nameCell = list.tableView(table, viewFor: nameColumn, row: 0) as! NSTableCellView
            let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.red.setFill()
                rect.fill()
                return true
            }
            let icon = nameCell.imageView!
            check(
                "view-options-list-icon-constraints-\(size)",
                icon.constraints.contains {
                    $0.firstAttribute == .width && $0.constant == CGFloat(size)
                }
                    && icon.constraints.contains {
                        $0.firstAttribute == .height && $0.constant == CGFloat(size)
                    })
            icon.image = image
            icon.frame = NSRect(x: 0, y: 0, width: size, height: size)
            let control = NSImageView(frame: icon.frame)
            control.image = image
            control.imageScaling = .scaleProportionallyDown
            let drawnPixels = redPixels(icon)
            let controlPixels = redPixels(control)
            print(
                "ICONRECEIPT size=\(size) redPixels=\(drawnPixels) downControlPixels=\(controlPixels)"
            )
            check(
                "view-options-list-glyph-upscales-\(size)",
                controlPixels > 0 && drawnPixels > controlPixels * 2)
        }
        let column = table.tableColumns.firstIndex { $0.identifier.rawValue == "date" }!
        func text(_ row: Int) -> String {
            (list.tableView(table, viewFor: table.tableColumns[column], row: row)
                as? NSTableCellView)?.textField?.stringValue ?? ""
        }
        let todayText = text(0)
        let yesterdayText = text(1)
        if Locale.current.language.languageCode?.identifier == "en" {
            check(
                "view-options-native-today-yesterday",
                todayText.contains("Today") && yesterdayText.contains("Yesterday"))
        } else {
            check(
                "view-options-native-relative-distinguishes-days",
                !todayText.isEmpty && !yesterdayText.isEmpty && todayText != yesterdayText)
        }
        list.setFormats(size: .decimal, date: .medium)
        check(
            "view-options-absolute-date-control", text(0) != todayText && text(1) != yesterdayText)
        check(
            "view-options-metadata-columns-delivered",
            table.tableColumns.filter { !$0.isHidden }.count == 8)
        list.setViewOptions(.defaults(.default))
        check(
            "view-options-default-columns-reset",
            table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == [
                "name", "date", "size",
            ]
                || Set(table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue })
                    == Set(["name", "size", "date"])
        )
        let field = NSTextField(string: "user-typed.txt")
        let grid = IconCollectionController(gallery: false)
        var gridOptions = FolderViewOptions.defaults(.default)
        gridOptions.labelPosition = .right
        gridOptions.gridSpacing = 24
        gridOptions.iconScale = 1.5
        gridOptions.showIconPreviews = false
        grid.applyStyle(rowHeight: 36, fontSize: 24, alternatingRows: false)
        grid.setViewOptions(gridOptions)
        grid.setEntries(
            [FileEntry(name: "sample.txt", isDirectory: false, size: 1, modificationDate: nil)],
            preserveState: false)
        let collection = grid.keyView as! NSCollectionView
        let layout = collection.collectionViewLayout as! NSCollectionViewFlowLayout
        let item = grid.collectionView(
            collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        item.view.frame = NSRect(origin: .zero, size: layout.itemSize)
        item.view.layoutSubtreeIfNeeded()
        check(
            "view-options-native-grid-spacing",
            layout.minimumLineSpacing == 24 && layout.minimumInteritemSpacing == 24)
        check(
            "view-options-native-right-label-geometry",
            (item.textField?.frame.minX ?? 0) >= (item.imageView?.frame.maxX ?? 1)
                && (item.textField?.frame.width ?? 0) > 0 && item.textField?.font?.pointSize == 24)
        let metadataHost = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
            backing: .buffered, defer: false)
        metadataHost.contentView = list.scrollView
        metadataHost.makeKeyAndOrderFront(nil)
        var metadataOptions = FolderViewOptions.defaults(.default)
        metadataOptions.columns = ["name", "version"]
        list.setViewOptions(metadataOptions)
        list.setEntries(
            (0..<10_000).map {
                FileEntry(
                    name: "fixture-\($0).txt", isDirectory: false, size: 1, modificationDate: nil)
            })
        metadataHost.contentView?.layoutSubtreeIfNeeded()
        check(
            "view-options-visible-metadata-not-whole-folder",
            settle { list.debugExtendedCacheCount > 0 } && list.debugExtendedCacheCount < 200)
        metadataHost.orderOut(nil)
        let suggestion = FilenameSuggestionController(
            field: field, url: URL(fileURLWithPath: "/fixture/original.txt"), dataless: false,
            generateAutomatically: false)
        suggestion.debugDeliver("suggested-name", ext: "txt")
        check("filename-suggestion-never-overwrites-typing", field.stringValue == "user-typed.txt")
        suggestion.debugUse()
        check(
            "filename-suggestion-explicit-accept-preserves-extension",
            field.stringValue == "suggested-name.txt")
        field.stringValue = "later-typing.txt"
        suggestion.cancel()
        suggestion.debugDeliver("stale", ext: "pdf")
        suggestion.debugUse()
        check(
            "filename-suggestion-cancel-rejects-late-delivery",
            field.stringValue == "later-typing.txt")

        for canceled in [true, false] {
            let input = NSTextField(string: "typed.txt")
            let session = FilenameSuggestionController(
                field: input, url: URL(fileURLWithPath: "/fixture/original.txt"),
                dataless: false, generateAutomatically: false)
            var release: CheckedContinuation<String?, Never>?
            var calls = 0
            session.debugStart(
                preview: { _ in await withCheckedContinuation { release = $0 } },
                suggest: { _, content in
                    calls += 1
                    return content == "fixture" ? "suggested" : nil
                })
            check("suggestion-preview-entered-\(canceled)", settle { release != nil })
            if canceled { session.cancel() }
            release?.resume(returning: "fixture")
            check("suggestion-task-terminal-\(canceled)", settle { session.debugFinished })
            check("suggestion-cancel-gates-model-\(canceled)", calls == (canceled ? 0 : 1))
            check(
                "suggestion-response-does-not-write-\(canceled)", input.stringValue == "typed.txt")
            session.debugUse()
            check(
                "suggestion-explicit-use-\(canceled)",
                input.stringValue == (canceled ? "typed.txt" : "suggested.txt"))
            session.cancel()
        }

        guard let window = view.window, let pane = leftTabs.activePane else {
            check("rename-warning-window", false)
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("unchanged".utf8).write(to: root.appendingPathComponent("original.txt"))
        } catch {
            check("rename-warning-fixture", false)
            return
        }
        let saved = prefs
        defer { prefs = saved }
        let sentinel = Self.debugRemoteScratchRoot.appendingPathComponent("window-sentinel.txt")
        do { try Data("live working copy".utf8).write(to: sentinel) } catch {
            check("audit-remote-scratch-sentinel", false)
        }
        let second = BrowserViewController(start: root, persistsSession: false)
        second.loadViewIfNeeded()
        check(
            "audit-second-browser-preserves-remote-working-copy",
            (try? Data(contentsOf: sentinel)) == Data("live working copy".utf8))
        prefs.warnBeforeChangingExtension = true
        window.makeKeyAndOrderFront(nil)
        setActiveSide(leftTabs, pane: pane)
        pane.debugClickViewSwitcher(.list)
        pane.navigate(to: root)
        check("rename-warning-fixture-listed", settle { pane.debugHasEntry("original.txt") })
        var folderOptions = pane.format.options
        folderOptions.calculateFolderSizes = false
        pane.setFolderViewOptions(folderOptions)
        toggleCalculateSizes()
        check(
            "view-options-folder-size-command-overrides-saved-off",
            pane.effectiveViewOptions.calculateFolderSizes == true)
        toggleCalculateSizes()
        check(
            "view-options-folder-size-command-round-trip",
            pane.effectiveViewOptions.calculateFolderSizes == false)
        let entry = FileEntry(
            name: "original.txt", isDirectory: false, size: 9, modificationDate: nil)
        commitLocalRename(entry, to: "changed.pdf", pane: pane)
        let presented = settle { window.attachedSheet != nil }
        check("rename-warning-actual-sheet", presented)
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        check(
            "rename-warning-cancel-keeps-original",
            settle { window.attachedSheet == nil }
                && fm.fileExists(atPath: root.appendingPathComponent("original.txt").path)
                && !fm.fileExists(atPath: root.appendingPathComponent("changed.pdf").path))
        commitLocalRename(entry, to: "changed.pdf", pane: pane)
        check("rename-warning-second-sheet", settle { window.attachedSheet != nil })
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        check(
            "rename-warning-accept-renames-real-fixture",
            settle {
                fm.fileExists(atPath: root.appendingPathComponent("changed.pdf").path)
                    && window.attachedSheet == nil
            } && !fm.fileExists(atPath: root.appendingPathComponent("original.txt").path))
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        do { try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true) } catch {
            check("view-options-origin-fixture", false)
            return
        }
        let untouched = folderFormats.format(for: elsewhere.path).options
        showViewOptions()
        check("view-options-production-sheet-shown", settle { window.attachedSheet != nil })
        func findRelative(_ candidate: NSView) -> NSButton? {
            if let button = candidate as? NSButton, button.identifier?.rawValue == "relativeDates" {
                return button
            }
            return candidate.subviews.compactMap(findRelative).first
        }
        if let sheet = window.attachedSheet, let content = sheet.contentView {
            let checkbox = findRelative(content)
            checkbox?.state = .off
            check("view-options-production-relative-control", checkbox != nil)
            pane.navigate(to: elsewhere)
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            check(
                "view-options-late-apply-owns-origin-not-current-folder",
                settle {
                    window.attachedSheet == nil
                        && folderFormats.format(for: root.path).options.dateDisplay == .medium
                } && pane.currentURL == elsewhere
                    && folderFormats.format(for: elsewhere.path).options == untouched)
        } else {
            check("view-options-late-apply-owns-origin-not-current-folder", false)
        }

        do {
            try Data("fixture".utf8).write(to: elsewhere.appendingPathComponent("marker.txt"))
            let preview = root.appendingPathComponent("preview.txt")
            try Data("fixture text".utf8).write(to: preview)
            let link = root.appendingPathComponent("preview-link.txt")
            try fm.createSymbolicLink(at: link, withDestinationURL: preview)
            check(
                "suggestion-preview-regular-file-control",
                Self.textPreview(of: preview) == "fixture text")
            check("suggestion-preview-rejects-symlink", Self.textPreview(of: link) == nil)
            check(
                "suggestion-preview-rejects-dataless-and-fifo",
                !Self.mayReadTextPreview(mode: mode_t(S_IFREG), flags: 0x4000_0000)
                    && !Self.mayReadTextPreview(mode: mode_t(S_IFIFO), flags: 0))
        } catch { check("review-preview-fixtures", false) }
        var childFormat = ViewFormat(viewMode: .column)
        childFormat.options.fontSize = 11
        rememberFormat(elsewhere, childFormat)
        pane.navigate(to: root)
        pane.debugClickViewSwitcher(.column)
        check("review-column-root-listed", settle { pane.debugHasEntry("elsewhere") })
        if let index = pane.entries.firstIndex(where: { $0.name == "elsewhere" }) {
            pane.debugColumnDrill(row: index)
        }
        func tables(_ view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        check(
            "review-column-child-mounted",
            settle {
                tables(pane.containerView).contains { $0.numberOfRows == 1 }
            })
        pane.debugColumnDrill(row: 0, column: 1)
        check("review-column-child-listed", pane.debugHasEntry("marker.txt"))
        let childKey = pane.keyView
        let originBefore = pane.contentClipView.bounds.origin
        var rootOptions = pane.format.options
        rootOptions.fontSize = 18
        rootOptions.dateDisplay = .relative
        let listingBefore = pane.debugListingCompletions
        pane.setFolderViewOptions(rootOptions)
        check(
            "view-options-drilled-column-root-ownership",
            settle {
                pane.debugListingCompletions > listingBefore
                    && pane.currentURL == elsewhere && pane.viewOptionsURL.path == root.path
                    && pane.selectedEntries.map(\.name) == ["marker.txt"]
                    && pane.keyView === childKey
                    && folderFormats.format(for: root.path).options.fontSize == 18
                    && folderFormats.format(for: elsewhere.path).options.fontSize == 11
            })
        let childTable = pane.keyView as? NSTableView
        let childCell =
            childTable?.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        print(
            "COLUMNRECEIPT completions=\(pane.debugListingCompletions-listingBefore) current=\(pane.currentURL.lastPathComponent) root=\(pane.viewOptionsURL.lastPathComponent) selected=\(pane.selectedEntries.map(\.name)) keySame=\(pane.keyView === childKey) storedRootFont=\(folderFormats.format(for: root.path).options.fontSize ?? -1) storedChildFont=\(folderFormats.format(for: elsewhere.path).options.fontSize ?? -1) drawnFont=\(childCell?.textField?.font?.pointSize ?? -1) xBefore=\(originBefore.x) xAfter=\(pane.contentClipView.bounds.origin.x)"
        )
        check(
            "view-options-drilled-column-actual-font-and-viewport",
            childCell?.textField?.font?.pointSize == 18
                && abs(pane.contentClipView.bounds.origin.x - originBefore.x) < 1)

        if settingsPanel == nil { showPreferences() }
        useCurrentViewAsDefault()
        check(
            "view-defaults-open-settings-synchronized",
            settings.debugPreferences.fontSize == 18 && settings.debugFontDefault == 18
                && settings.debugPreferences.dateDisplay == .relative
                && folderFormats.defaultFormat.options.fontSize == nil
                && folderFormats.defaultFormat.options.dateDisplay == nil)
        check(
            "view-defaults-unrelated-settings-edit-delivered",
            settings.debugTogglePreference(\.alternatingRows))
        check(
            "view-defaults-unrelated-edit-does-not-revert",
            prefs.fontSize == 18 && prefs.dateDisplay == .relative)

        check("retention-test-automation-no-owner-trash", PathemApp.isAutomationLaunch)
        if PathemApp.isAutomationLaunch {
            let retentionBefore = trashRetention.enabled
            defer { trashRetention.setPreference(retentionBefore) }
            second.showPreferences()
            trashRetention.setPreference(true)
            let stale = prefs
            check(
                "retention-second-window-explicit-disable",
                second.settings.debugTogglePreference(\.trashAfter30Days))
            receiveSettingsPreferences(stale)
            check(
                "retention-stale-snapshot-cannot-reenable",
                !trashRetention.enabled && !prefs.trashAfter30Days && !second.prefs.trashAfter30Days
                    && !settings.debugPreferences.trashAfter30Days
                    && !second.settings.debugPreferences.trashAfter30Days)
            check(
                "retention-unrelated-real-control",
                settings.debugTogglePreference(\.alternatingRows))
            trashRetention.initialize(enabled: true)
            check(
                "retention-stale-new-window-cannot-reseed-or-schedule",
                !trashRetention.enabled && !prefs.trashAfter30Days
                    && !trashRetention.debugHasScheduledWork)
            let persisted = Self.preferencesURL.flatMap { loadConfig(Preferences.self, from: $0) }
            check("retention-stale-snapshot-persisted-off", persisted?.trashAfter30Days == false)
            second.closeSettingsPanel()
        }
        closeSettingsPanel()

        let connection = RemoteConnection(name: "Fixture", proto: .sftp, host: "fixture.invalid")
        let context = (connection: connection, path: "/origin", password: "")
        let otherConnection = RemoteConnection(name: "Other", proto: .sftp, host: "other.invalid")
        check(
            "rename-origin-local-and-remote-controls",
            Self.renameContextMatches(nil, nil) && Self.renameContextMatches(context, context)
                && !Self.renameContextMatches(nil, context)
                && !Self.renameContextMatches(context, nil)
                && !Self.renameContextMatches(context, (connection, "/elsewhere", ""))
                && !Self.renameContextMatches(context, (otherConnection, "/origin", ""))
                && !Self.renameContextMatches(context, (connection, "/origin", "changed")))
    }
}
#endif
