import AppKit
import PathemEngine
import PathemTerminal
import Quartz

// The headless smoke harness: a single diagnostic pass exercising most subsystems (panes,
// terminal, drag/drop, file ops, remote backends, and more) without a UI test runner. Split
// out of BrowserViewController to keep that file focused.
@MainActor
extension BrowserViewController {
    func smokeReport() -> (ok: Bool, lines: [String]) {
        var lines: [String] = []
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            if !pass { ok = false }
            lines.append("\(pass ? "ok  " : "FAIL") \(name) (\(detail))")
        }
        let size = view.window?.frame.size ?? .zero
        check("window-size", size.width >= 700 && size.height >= 400, "\(Int(size.width))x\(Int(size.height))")
        let sidebarW = sidebar.containerView.frame.width
        check("sidebar-width", (100...360).contains(sidebarW), "\(Int(sidebarW))")
        check("left-pane-visible", leftTabs.containerView.frame.width > 50, "\(Int(leftTabs.containerView.frame.width))")
        check("right-pane-visible", rightTabs.containerView.frame.width > 50, "\(Int(rightTabs.containerView.frame.width))")
        // The file list must actually have vertical room. A near-zero height with the pane at
        // full width is the "blank panes" regression: the tab bar / toolbar stacks stretched and
        // squeezed the list flat. Rows exist (data is fine) but nothing is visible.
        let leftContentH = leftTabs.activePane?.debugContentHeight() ?? 0
        let rightContentH = rightTabs.activePane?.debugContentHeight() ?? 0
        check("pane-content-not-squished", leftContentH > 150 && rightContentH > 150,
            "left=\(Int(leftContentH)) right=\(Int(rightContentH))")
        check("left-pane-has-rows", leftTabs.activePane?.entries.isEmpty == false, "\(leftTabs.activePane?.entries.count ?? -1) entries")
        // Regression: squeeze the right pane narrow, widen it back, and the list columns
        // must refill the pane. The old frame-based chrome measurement read the blank
        // space as chrome and locked every column at its floor (tiny columns filling
        // less than half the pane).
        setRightPaneFraction(0.22)
        view.layoutSubtreeIfNeeded()
        setRightPaneFraction(0.5)
        view.layoutSubtreeIfNeeded()
        if let fill = rightTabs.activePane?.debugColumnFillRatio() {
            check("list-columns-refill", fill >= 0.9, String(format: "fill=%.2f", fill))
        } else {
            lines.append("info list-columns-refill (right pane is not a list view)")
        }
        lines.append("info left-folder (\(leftTabs.activePane?.currentURL.path ?? "?"))")
        // The listing reads off the main thread now; a stale read of a folder we've navigated
        // away from (or a superseded reload) must not clobber the current rows.
        check("reload-superseding-guard", leftTabs.activePane?.debugSupersededListingIsDropped() == true, "stale reads dropped")
        // Regression: draggingEnded: must reach the ObjC runtime. It is an optional
        // NSDraggingDestination method NSView does not implement, so a plain Swift override is NOT
        // exposed as @objc -- AppKit's cross-app drag completion then sends draggingEnded:, hits an
        // unrecognized selector, swallows the exception, and the drag session never concludes, so
        // every drag after a drag-out to another app is dead until relaunch. @objc on the override
        // is the fix; this guards against silently dropping it.
        let draggingEndedSel = Selector(("draggingEnded:"))
        let tableExposes = KeyTableView().responds(to: draggingEndedSel)
        let gridExposes = KeyCollectionView(frame: .zero).responds(to: draggingEndedSel)
        check("drag-ended-selector-exposed", tableExposes && gridExposes, "table=\(tableExposes) grid=\(gridExposes)")
        // Finder-style rename: Return triggers rename (not open), and beginning an edit on a
        // single selection flips the list's name cell editable. Ending it unchanged (resign first
        // responder) must rename nothing, so this leaves no filesystem state behind.
        check(
            "rename-return-binding", Keymap.defaultBindings["return"] == "files.rename",
            Keymap.defaultBindings["return"] ?? "nil")
        if let pane = leftTabs.activePane, let first = pane.entries.first {
            pane.select(name: first.name)
            let began = pane.beginInlineRename()
            check("inline-rename-begins", began, "began=\(began)")
            // A reload arriving mid-edit (a background folder change) must abandon the edit, never
            // commit a half-typed name. Simulate the reload and confirm the edit was cancelled.
            let wasActive = pane.debugInlineEditActive
            pane.debugReloadContentInPlace()
            check(
                "inline-rename-cancels-on-reload", wasActive && !pane.debugInlineEditActive,
                "active=\(wasActive) afterReload=\(pane.debugInlineEditActive)")
            view.window?.makeFirstResponder(nil)  // end any edit with no change
        }
        // Empty Trash must be reachable from the Trash location with nothing selected: the folder
        // predicate that gates the background-menu entry has to recognize ~/.Trash and reject others.
        let trashDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let home = FileManager.default.homeDirectoryForCurrentUser
        check(
            "empty-trash-folder-predicate",
            FileContextMenuController.isTrashFolder(trashDir) && !FileContextMenuController.isTrashFolder(home),
            "trash=\(FileContextMenuController.isTrashFolder(trashDir)) home=\(FileContextMenuController.isTrashFolder(home))")
        // The preview pane routes PDFs to the PDFKit viewer (real zoom/scroll/print) and everything
        // else to Quick Look.
        let preview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let tmpPDF = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-smoke.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        doc.write(to: tmpPDF)
        preview.show(tmpPDF)
        let pdfRouted = preview.debugShowingPDF
        preview.show(URL(fileURLWithPath: "/etc/hosts"))  // a non-PDF -> Quick Look
        let qlRouted = !preview.debugShowingPDF
        try? FileManager.default.removeItem(at: tmpPDF)
        check("preview-routes-pdf-vs-quicklook", pdfRouted && qlRouted, "pdf=\(pdfRouted) ql=\(qlRouted)")
        // An encrypted PDF loads as a non-nil but locked document; it must fall through to Quick
        // Look (which prompts for the password), not render blank behind dead zoom/print controls.
        let lockedPDF = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-smoke-locked.pdf")
        let lockedDoc = PDFDocument()
        lockedDoc.insert(PDFPage(), at: 0)
        lockedDoc.write(
            to: lockedPDF, withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "x"])
        let lockedPreview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        lockedPreview.show(lockedPDF)
        let lockedRoutedToQL = !lockedPreview.debugShowingPDF
        try? FileManager.default.removeItem(at: lockedPDF)
        check("encrypted-pdf-falls-back-to-quicklook", lockedRoutedToQL, "showingPDF=\(lockedPreview.debugShowingPDF)")
        // Markup persists: add a highlight and save, then reload from disk and confirm the annotation
        // round-tripped into the PDF (the core of the Preview-like editing path).
        let markupPDF = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-markup-\(UUID().uuidString).pdf")
        let markupDoc = PDFDocument()
        markupDoc.insert(PDFPage(), at: 0)
        markupDoc.write(to: markupPDF)
        let markupPreview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        markupPreview.show(markupPDF)
        let saved = markupPreview.debugMarkUpAndSave(rect: CGRect(x: 40, y: 60, width: 120, height: 18))
        let reloadedAnnotations = PDFDocument(url: markupPDF)?.page(at: 0)?.annotations.count ?? 0
        try? FileManager.default.removeItem(at: markupPDF)
        check(
            "pdf-markup-persists", saved && reloadedAnnotations >= 1,
            "saved=\(saved) annotations=\(reloadedAnnotations)")
        // The markup toggle reveals the tool row; picking a tool arms it and picking it again disarms
        // it (guards the tag-based selectTool mapping).
        markupPreview.debugToggleMarkup(true)
        let barShown = markupPreview.debugMarkupVisible
        markupPreview.debugPickTool(.arrow)
        let armed = markupPreview.debugActiveTool == .arrow
        markupPreview.debugPickTool(.arrow)
        let disarmed = markupPreview.debugActiveTool == .none
        check(
            "markup-tool-toggle", barShown && armed && disarmed,
            "bar=\(barShown) armed=\(armed) disarmed=\(disarmed)")
        // Freehand ink round-trips with correct geometry: draw an "L" and confirm the reloaded ink
        // annotation spans the input points (guards the bounds-relative path fix; absolute page
        // coordinates put the stroke off-page and it rendered blank).
        let inkPDF = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-ink-\(UUID().uuidString).pdf")
        let inkDoc = PDFDocument()
        inkDoc.insert(PDFPage(), at: 0)
        inkDoc.write(to: inkPDF)
        let inkPreview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        inkPreview.show(inkPDF)
        let inkedOK = inkPreview.debugInkAndSave(points: [
            CGPoint(x: 120, y: 680), CGPoint(x: 120, y: 400), CGPoint(x: 420, y: 400),
        ])
        let inkBounds =
            (PDFDocument(url: inkPDF)?.page(at: 0)?.annotations.first { $0.type == "Ink" })?.bounds
            ?? .zero
        try? FileManager.default.removeItem(at: inkPDF)
        check(
            "pdf-ink-roundtrips", inkedOK && inkBounds.width > 250 && inkBounds.height > 250,
            "ok=\(inkedOK) bounds=\(inkBounds)")
        // Shapes / line / arrow round-trip with the right annotation types (rectangle -> Square,
        // oval -> Circle, line and arrow -> Line).
        let shapesPDF = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-shapes-\(UUID().uuidString).pdf")
        let shapesDoc = PDFDocument()
        shapesDoc.insert(PDFPage(), at: 0)
        shapesDoc.write(to: shapesPDF)
        let shapesPreview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        shapesPreview.show(shapesPDF)
        let shapesOK = shapesPreview.debugDrawShapesAndSave()
        let shapeTypes = Set((PDFDocument(url: shapesPDF)?.page(at: 0)?.annotations ?? []).map { $0.type ?? "" })
        try? FileManager.default.removeItem(at: shapesPDF)
        check(
            "pdf-shapes-roundtrip",
            shapesOK && shapeTypes.isSuperset(of: ["Square", "Circle", "Line"]),
            "ok=\(shapesOK) types=\(shapeTypes.sorted())")
        // Text box + sticky note round-trip with the right types (FreeText, Text).
        let textPDF = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-text-\(UUID().uuidString).pdf")
        let textDoc = PDFDocument()
        textDoc.insert(PDFPage(), at: 0)
        textDoc.write(to: textPDF)
        let textPreview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textPreview.show(textPDF)
        let textOK = textPreview.debugDrawTextAndSave()
        let textTypes = Set((PDFDocument(url: textPDF)?.page(at: 0)?.annotations ?? []).map { $0.type ?? "" })
        try? FileManager.default.removeItem(at: textPDF)
        check(
            "pdf-text-roundtrip", textOK && textTypes.isSuperset(of: ["FreeText", "Text"]),
            "ok=\(textOK) types=\(textTypes.sorted())")
        // Open in Other Pane: PDFs/images are viewable; presenting a viewer overlays the pane and
        // dismiss clears it (so browsing returns).
        check(
            "viewable-predicate",
            DocumentPreviewView.isViewable(URL(fileURLWithPath: "/x/a.pdf"))
                && !DocumentPreviewView.isViewable(URL(fileURLWithPath: "/x/a.txt")),
            "pdf=\(DocumentPreviewView.isViewable(URL(fileURLWithPath: "/x/a.pdf")))")
        if let other = rightTabs.activePane {
            other.presentViewer(URL(fileURLWithPath: "/etc/hosts"))
            let shown = other.isShowingViewer
            other.dismissViewer()
            check("open-in-other-pane-viewer", shown && !other.isShowingViewer, "shown=\(shown)")
            // The view switcher sits above the overlay, so switching view mode must close the viewer
            // (not leave a stale, detached overlay that leaks its loaded document).
            let originalMode = other.debugViewMode
            other.presentViewer(URL(fileURLWithPath: "/etc/hosts"))
            let beforeSwitch = other.isShowingViewer
            other.setViewMode(originalMode == .icon ? .list : .icon)
            check(
                "viewer-dismissed-on-view-switch", beforeSwitch && !other.isShowingViewer,
                "before=\(beforeSwitch) after=\(other.isShowingViewer)")
            other.setViewMode(originalMode)  // restore for later checks
        }
        // Track A8: the image-only pane toolbar controls (back/forward/up/sort/actions/view) carry
        // VoiceOver labels, not just tooltips.
        check(
            "toolbar-accessibility-labels", leftTabs.activePane?.debugToolbarAccessibilityLabeled() == true,
            "back/forward/up/sort/actions/view labeled")
        // Track C: the reconciled translations actually load at runtime -- not just that the
        // .strings parse. Resolve a known key through the de and ja bundles and confirm it comes
        // back translated, catching a packaging regression that would silently hide every locale.
        var l10nOK = true
        var l10nDetail = ""
        for (lang, expected) in [("de", "Öffnen"), ("ja", "開く")] {
            if let path = pathemResourceBundle.path(forResource: lang, ofType: "lproj"),
                let bundle = Bundle(path: path)
            {
                let resolved = bundle.localizedString(forKey: "common.open", value: "MISSING", table: nil)
                if resolved != expected { l10nOK = false; l10nDetail += " \(lang)=\(resolved)" }
            } else {
                l10nOK = false
                l10nDetail += " \(lang)=noBundle"
            }
        }
        check("localization-loads-at-runtime", l10nOK, l10nDetail.isEmpty ? "de+ja resolve" : l10nDetail)
        // Empty Trash appears on the Trash background (empty-space right-click), not only via a
        // selected item -- and only in the Trash, not an ordinary folder.
        let trashFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let homeFolderURL = FileManager.default.homeDirectoryForCurrentUser
        let trashHasEmpty = leftTabs.activePane?.debugBackgroundMenuHasEmptyTrash(forDir: trashFolderURL) ?? false
        let homeHasEmpty = leftTabs.activePane?.debugBackgroundMenuHasEmptyTrash(forDir: homeFolderURL) ?? false
        check("trash-background-empty-trash", trashHasEmpty && !homeHasEmpty,
            "trash=\(trashHasEmpty) home=\(homeHasEmpty)")
        // A8: the list name cell reads the clean filename to VoiceOver, not the git/tag decoration.
        // Check the first entry row (a grouped view puts a header at row 0); skip only if there are
        // no entry rows, so grouping can't turn this into a false failure.
        if let axClean = leftTabs.activePane?.debugFirstEntryNameAXMatches() {
            check("cell-accessibility-clean-name", axClean, "name cell exposes the filename")
        }
        // The sorted column must show its indicator on load, not only after a header
        // click (setting sortDescriptors programmatically doesn't draw the triangle).
        if let sort = leftTabs.activePane?.debugSortIndicator {
            check(
                "sort-indicator-drawn", sort.drawn,
                "column=\(sort.column) \(sort.ascending ? "ascending" : "descending")")
        } else {
            lines.append("info sort-indicator (active pane is not a list view)")
        }
        // Open the terminal only if needed (a prior run may have persisted it
        // open), check, then undo exactly what we changed so the run leaves no
        // state behind (pref, visibility, or a spawned shell).
        let wasVisible = !terminal.view.isHidden
        let wasRunning = terminal.isRunning
        let savedVisible = UserDefaults.standard.bool(forKey: "pathem.terminalVisible")
        if terminal.view.isHidden { toggleTerminal() }
        check("terminal-opens", !terminal.view.isHidden && terminal.isRunning,
            "visible=\(!terminal.view.isHidden) running=\(terminal.isRunning)")
        if !wasVisible, !terminal.view.isHidden { toggleTerminal() }  // we opened it; hide again
        if !wasRunning, terminal.isRunning { terminal.shutdown() }  // we started the shell; stop it
        UserDefaults.standard.set(savedVisible, forKey: "pathem.terminalVisible")
        // Icon view hosts the same entries (checked in isolation so the smoke run
        // doesn't persist a view-mode rule for the home folder).
        let iconView = IconCollectionController(gallery: false)
        iconView.setEntries(leftTabs.activePane?.entries ?? [], preserveState: false)
        check("icon-view-renders", iconView.entries.count > 0, "\(iconView.entries.count) entries")
        // Gallery (preview + filmstrip): exercise setEntries so a crash/hang there is caught.
        let galleryView = GalleryController()
        galleryView.directoryURL = leftTabs.activePane?.currentURL
        galleryView.setEntries(leftTabs.activePane?.entries ?? [], preserveState: false)
        check("gallery-view-renders", galleryView.entries.count > 0, "\(galleryView.entries.count) entries")
        // The bundled changelog is present and parses into versioned entries; the Release Notes
        // window (Help menu, on demand) renders from exactly this.
        let changelogEntries =
            pathemResourceBundle.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { ChangelogParser.parse($0) } ?? []
        check("changelog-bundled-and-parses", changelogEntries.count >= 1, "\(changelogEntries.count) versions")
        // The "Update Ready" title-bar button stays hidden until an update is pending, then shows.
        // Sparkle is dormant on unsigned builds, so simulate a pending update, confirm the button
        // becomes visible, then restore so the run leaves no state behind.
        if let updater {
            installUpdateButtonIfNeeded()
            let hadPending = updater.pendingUpdateVersion
            updater.debugSetPendingUpdate(version: "9.9.9")
            let accessory = view.window?.titlebarAccessoryViewControllers.first { $0 is UpdateButtonAccessory }
            let shown = accessory?.isHidden == false && updater.pendingUpdateVersion == "9.9.9"
            check(
                "update-button-shows-when-pending", shown,
                "pending=\(updater.pendingUpdateVersion ?? "nil") hidden=\(accessory?.isHidden.description ?? "no-accessory")")
            updater.debugSetPendingUpdate(version: hadPending)  // restore
        }
        // Dialog sizing guard: growToFitContent must expand a window whose content is taller than
        // its designed height (so a button row can't clip past the border), and must never shrink
        // below the designed size (so scroll-view heights stay intact). Exercises both directions.
        do {
            let win = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                styleMask: [.titled], backing: .buffered, defer: true)
            let content = win.contentView!
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                inner.topAnchor.constraint(equalTo: content.topAnchor),
                inner.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                inner.heightAnchor.constraint(equalToConstant: 300),  // taller than the 80pt window
            ])
            win.growToFitContent()
            let sized = win.contentView!.frame.size
            check(
                "dialog-grows-to-fit-content", sized.height >= 300 && sized.width >= 200,
                "grew h 80->\(Int(sized.height)); kept designed w (\(Int(sized.width)))")
        }
        // Preview pane must not collapse the panes to zero (the auto-preview layout bug):
        // toggling it on keeps the panes wide, and toggling it off restores their width.
        check("preview-pane-keeps-panes", debugPreviewToggleKeepsPanes(), "panes survive preview toggle")
        // Every context-menu command resolves to an icon (a mistyped SF Symbol name would
        // silently drop the glyph, leaving the item icon-less).
        let iconlessCommands = FileListController.contextCommands.filter { MenuIcons.image(forCommand: $0.id) == nil }
        check(
            "context-menu-icons", iconlessCommands.isEmpty,
            iconlessCommands.isEmpty ? "all present" : "missing: \(iconlessCommands.map(\.id))")
        // Copy Path / Copy Name are offered in the right-click menu everywhere (all views share it).
        let ctxIDs = Set(FileListController.contextCommands.map(\.id))
        check("copy-path-in-context-menu", ctxIDs.isSuperset(of: ["files.copyPath", "files.copyName"]),
            "copyPath=\(ctxIDs.contains("files.copyPath")) copyName=\(ctxIDs.contains("files.copyName"))")
        // Every default hotkey resolves to a registered command -- catches a binding that
        // points at a renamed or removed command id (a silently dead key). The wiring check
        // between the keymap and the command registry.
        let deadHotkeys = Keymap.standard.bindings.filter { commands.command($0.value) == nil }
        check(
            "keymap-bindings-resolve", deadHotkeys.isEmpty,
            deadHotkeys.isEmpty
                ? "\(Keymap.standard.bindings.count) hotkeys -> commands"
                : "dead: \(deadHotkeys.map { "\($0.key)=\($0.value)" }.sorted())")
        // The whole hotkey dispatch path works end to end: a Delete chord resolves through the
        // keymap to files.trash and would fire (routed the same way KeyTableView.keyDown does).
        let deleteCmd = keymap.commandID(for: KeyChord(key: "delete"))
        check(
            "keymap-dispatch", deleteCmd == "files.trash" && commands.command("files.trash") != nil,
            "delete -> \(deleteCmd ?? "nil")")
        // Every super-drag flick direction maps to a registered command (same wiring check).
        let deadFlicks = DragGestureMap.standard.bindings.filter { commands.command($0.value) == nil }
        check(
            "drag-gestures-resolve", deadFlicks.isEmpty,
            deadFlicks.isEmpty
                ? "\(DragGestureMap.standard.bindings.count) flicks -> commands"
                : "dead: \(deadFlicks.map { "\($0.key)=\($0.value)" }.sorted())")
        // The super-drag handler drives the trail: a synthetic drag shows it on begin and
        // hides it on end (the drawing itself is only visible during a live drag).
        let savedFlick = prefs.dragFlickActions
        prefs.dragFlickActions = true
        handleDragSession(.began(screen: .zero, showsHint: true))  // a row super-drag
        handleDragSession(.moved(screen: NSPoint(x: 90, y: 8)))  // a clear rightward flick
        let trailShown = !dragTrail.isHidden
        let hint = dragTrail.hint  // names the mapped command + its shortcut
        handleDragSession(.ended(flick: nil))
        // An empty-space stroke draws the trail too, but with no flick label (it runs the gesture map).
        handleDragSession(.began(screen: .zero, showsHint: false))
        handleDragSession(.moved(screen: NSPoint(x: 90, y: 8)))
        let emptyTrailShown = !dragTrail.isHidden
        let emptyHint = dragTrail.hint
        handleDragSession(.ended(flick: nil))
        prefs.dragFlickActions = savedFlick
        check("super-drag-trail", trailShown && dragTrail.isHidden, "shown=\(trailShown)")
        check("super-drag-hint", !hint.isEmpty, "hint=\"\(hint)\"")
        check(
            "empty-space-drag-trail", emptyTrailShown && emptyHint.isEmpty,
            "shown=\(emptyTrailShown) hint=\"\(emptyHint)\"")
        // Hiding an auto-detected system item (e.g. a stale Google Drive mount) removes it from the
        // sidebar; Restore Hidden Items brings it back.
        if let sysPath = sidebar.debugSystemItemPaths.first {
            sidebar.debugHideSystemItem(sysPath)
            let hidden = !sidebar.debugSystemItemPaths.contains(sysPath)
            sidebar.debugRestoreHiddenItems()
            let restored = sidebar.debugSystemItemPaths.contains(sysPath)
            check("sidebar-hide-restore-system-item", hidden && restored,
                "path=\(sysPath) hidden=\(hidden) restored=\(restored)")
        }
        // Eject heuristic (Finder parity): the boot volume never ejects; an external USB/Thunderbolt
        // SSD (ejectable == removable == false, but internal == false) does; a plain internal partition
        // does not; removable media and network mounts do.
        let bootEjects = SidebarController.volumeIsEjectable(
            isBrowsable: true, isEjectable: false, isRemovable: false, isLocal: true, isInternal: true, isRootFileSystem: true)
        let extSSD = SidebarController.volumeIsEjectable(
            isBrowsable: true, isEjectable: false, isRemovable: false, isLocal: true, isInternal: false, isRootFileSystem: false)
        let internalPart = SidebarController.volumeIsEjectable(
            isBrowsable: true, isEjectable: false, isRemovable: false, isLocal: true, isInternal: true, isRootFileSystem: false)
        let usbStick = SidebarController.volumeIsEjectable(
            isBrowsable: true, isEjectable: true, isRemovable: true, isLocal: true, isInternal: false, isRootFileSystem: false)
        let networkMount = SidebarController.volumeIsEjectable(
            isBrowsable: true, isEjectable: false, isRemovable: false, isLocal: false, isInternal: nil, isRootFileSystem: false)
        // A firmlinked system volume (Data/home) reports local == false but is non-browsable: must NOT eject.
        let hiddenSystem = SidebarController.volumeIsEjectable(
            isBrowsable: false, isEjectable: false, isRemovable: false, isLocal: false, isInternal: nil, isRootFileSystem: false)
        check("volume-eject-heuristic",
            !bootEjects && extSSD && !internalPart && usbStick && networkMount && !hiddenSystem,
            "boot=\(bootEjects) extSSD=\(extSSD) internal=\(internalPart) usb=\(usbStick) net=\(networkMount) hidden=\(hiddenSystem)")

        // pathem CLI install safety: linkPointsToUs recognizes our own symlink and rejects one that
        // points elsewhere, so install()/remove() never clobber a file that isn't ours.
        let cliDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        let bundledCLI = cliDir.appendingPathComponent("pathem-cli")
        FileManager.default.createFile(atPath: bundledCLI.path, contents: Data("x".utf8))
        let oursLink = cliDir.appendingPathComponent("pathem")
        try? FileManager.default.createSymbolicLink(at: oursLink, withDestinationURL: bundledCLI)
        let foreignLink = cliDir.appendingPathComponent("pathem-foreign")
        try? FileManager.default.createSymbolicLink(at: foreignLink, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let recognizesOurs = PathemCLIInstall.linkPointsToUs(oursLink, bundled: bundledCLI)
        let rejectsForeign = !PathemCLIInstall.linkPointsToUs(foreignLink, bundled: bundledCLI)
        check("cli-install-link-safety", recognizesOurs && rejectsForeign,
            "ours=\(recognizesOurs) rejectsForeign=\(rejectsForeign)")
        try? FileManager.default.removeItem(at: cliDir)

        // Sublime integration: installing into an owned package dir writes our files (plugin driving
        // the pathem:// scheme), and remove deletes only that folder -- fully reversible.
        let subRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-sublime-\(UUID().uuidString)")
        let subPkg = subRoot.appendingPathComponent("Packages/Pathem")
        try? SublimeIntegration.install(into: subPkg)
        let wrotePlugin = FileManager.default.fileExists(atPath: subPkg.appendingPathComponent("pathem_reveal.py").path)
        let wroteMenu = FileManager.default.fileExists(atPath: subPkg.appendingPathComponent("Side Bar.sublime-menu").path)
        let pluginText = (try? String(contentsOf: subPkg.appendingPathComponent("pathem_reveal.py"), encoding: .utf8)) ?? ""
        let usesScheme = pluginText.contains("pathem://reveal")
        try? SublimeIntegration.remove(at: subPkg)
        let subRemoved = !FileManager.default.fileExists(atPath: subPkg.path)
        check("sublime-integration-install-remove", wrotePlugin && wroteMenu && usesScheme && subRemoved,
            "plugin=\(wrotePlugin) menu=\(wroteMenu) scheme=\(usesScheme) removed=\(subRemoved)")
        try? FileManager.default.removeItem(at: subRoot)

        // TextMate integration: an owned .tmbundle with a nested Commands/ file that drives the
        // pathem:// scheme; remove deletes only that bundle.
        let tmRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-tm-\(UUID().uuidString)")
        let tmBundle = tmRoot.appendingPathComponent("Bundles/Pathem.tmbundle")
        try? TextMateIntegration.install(into: tmBundle)
        let wroteInfo = FileManager.default.fileExists(atPath: tmBundle.appendingPathComponent("info.plist").path)
        let cmdURL = tmBundle.appendingPathComponent("Commands/Reveal in Pathem.tmCommand")
        let wroteCommand = FileManager.default.fileExists(atPath: cmdURL.path)
        let cmdText = (try? String(contentsOf: cmdURL, encoding: .utf8)) ?? ""
        let tmScheme = cmdText.contains("pathem://reveal")
        try? TextMateIntegration.remove(at: tmBundle)
        let tmRemoved = !FileManager.default.fileExists(atPath: tmBundle.path)
        check("textmate-integration-install-remove", wroteInfo && wroteCommand && tmScheme && tmRemoved,
            "info=\(wroteInfo) command=\(wroteCommand) scheme=\(tmScheme) removed=\(tmRemoved)")
        try? FileManager.default.removeItem(at: tmRoot)

        // JetBrains integration: writes a Pathem-owned tools/Pathem.xml into each IDE profile (never
        // the user's External Tools.xml); the emitted XML must be well-formed and drive pathem-cli.
        let jbRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-jb-\(UUID().uuidString)")
        let jbProfile = jbRoot.appendingPathComponent("IntelliJIdea2024.1")
        try? FileManager.default.createDirectory(at: jbProfile, withIntermediateDirectories: true)
        try? JetBrainsIntegration.install(into: [jbProfile])
        let jbFile = JetBrainsIntegration.toolFile(in: jbProfile)
        let jbWrote = FileManager.default.fileExists(atPath: jbFile.path)
        let jbText = (try? String(contentsOf: jbFile, encoding: .utf8)) ?? ""
        let jbWellFormed = (try? XMLDocument(xmlString: jbText)) != nil
        let jbContent = jbText.contains("<toolSet name=\"Pathem\">") && jbText.contains("reveal &quot;$FilePath$&quot;")
        try? JetBrainsIntegration.remove(from: [jbProfile])
        let jbRemoved = !FileManager.default.fileExists(atPath: jbFile.path)
        check("jetbrains-integration-install-remove", jbWrote && jbWellFormed && jbContent && jbRemoved,
            "wrote=\(jbWrote) xml=\(jbWellFormed) content=\(jbContent) removed=\(jbRemoved)")
        try? FileManager.default.removeItem(at: jbRoot)

        // Torrent save path: a real configured folder is honored; empty or a missing folder falls
        // back to the system Downloads folder.
        let tsvDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-tsv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tsvDir, withIntermediateDirectories: true)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        let tsvPicked = TorrentSavePath.resolve(tsvDir.path) == tsvDir.path
        let tsvEmpty = TorrentSavePath.resolve("") == downloads
        let tsvMissing = TorrentSavePath.resolve("/no/such/dir-\(UUID().uuidString)") == downloads
        check("torrent-save-path", tsvPicked && tsvEmpty && tsvMissing,
            "picked=\(tsvPicked) empty=\(tsvEmpty) missing=\(tsvMissing)")
        try? FileManager.default.removeItem(at: tsvDir)

        // Overflow (…) toolbar menu: a Theme submenu listing every skin + appearance, plus Settings.
        let overflowMenu = NSMenu()
        populateOverflowMenu(overflowMenu)
        let themeSub = overflowMenu.items.first { $0.title == L("overflow.theme", "Theme") }?.submenu
        // Every skin is listed (by name; "System" doubles as an appearance label, so match by presence).
        let allPresets = ThemePreset.presets.allSatisfy { preset in
            themeSub?.items.contains { $0.title == preset.name } ?? false
        }
        let hasSettings = overflowMenu.items.contains { $0.title == L("overflow.settings", "Settings…") }
        check("overflow-menu", themeSub != nil && allPresets && hasSettings,
            "theme=\(themeSub != nil) allPresets=\(allPresets) settings=\(hasSettings)")

        // Stale-build watch: a strictly-newer installed build (past the 5s grace) is stale; nil,
        // near-launch, and older are not -- so it never nags about the build it launched from.
        let launchRef = Date()
        let sbNewer = StaleBuildWatch.isStale(installed: launchRef.addingTimeInterval(60), launched: launchRef)
        let sbNil = StaleBuildWatch.isStale(installed: nil, launched: launchRef)
        let sbGrace = StaleBuildWatch.isStale(installed: launchRef.addingTimeInterval(2), launched: launchRef)
        let sbOlder = StaleBuildWatch.isStale(installed: launchRef.addingTimeInterval(-60), launched: launchRef)
        check("stale-build-watch", sbNewer && !sbNil && !sbGrace && !sbOlder,
            "newer=\(sbNewer) nil=\(sbNil) grace=\(sbGrace) older=\(sbOlder)")

        // Photos export naming: uniqueURL never overwrites an existing export.
        let photosDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-photos-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let firstExport = PhotoLibrary.uniqueURL(in: photosDir, name: "IMG_1.jpg")
        FileManager.default.createFile(atPath: firstExport.path, contents: Data())
        let secondExport = PhotoLibrary.uniqueURL(in: photosDir, name: "IMG_1.jpg")
        let photosUnique = firstExport.lastPathComponent == "IMG_1.jpg" && secondExport.lastPathComponent == "IMG_1 2.jpg"
        let photosCommand = commands.command("photos.open") != nil
        check("photos-library", photosUnique && photosCommand,
            "unique=\(photosUnique) (\(secondExport.lastPathComponent)) command=\(photosCommand)")
        try? FileManager.default.removeItem(at: photosDir)

        // Vision subject lift: the Remove Background command is registered, and the cutout name maps
        // a photo to a transparent-PNG sibling.
        let rbRegistered = commands.command("image.removeBackground") != nil
        let cutoutOK = SubjectLift.cutoutName(for: "beach.heic") == "beach Cutout.png"
        check("remove-background", rbRegistered && cutoutOK, "registered=\(rbRegistered) cutout=\(cutoutOK)")

        // Vision auto-tag: the command is registered; classifying a non-image yields no tags (safe).
        let atRegistered = commands.command("image.autoTag") != nil
        let noJunkTags = ImageClassifier.classify(url: URL(fileURLWithPath: "/etc/hosts")).isEmpty
        check("auto-tag", atRegistered && noJunkTags, "registered=\(atRegistered) noJunk=\(noJunkTags)")

        // Near-duplicate culler: command registered; a cluster's extras exclude the keeper.
        let ndRegistered = commands.command("image.findNearDuplicates") != nil
        let ndGroup = NearDuplicatePhotos.Group(
            urls: [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.jpg"), URL(fileURLWithPath: "/c.jpg")], keepIndex: 0)
        check("near-duplicates", ndRegistered && ndGroup.extras.count == 2,
            "registered=\(ndRegistered) extras=\(ndGroup.extras.count)")

        // Media conversion hub: both commands registered; targets map to the right file extensions.
        let extractReg = commands.command("media.extractAudio") != nil
        let mp4Reg = commands.command("media.convertToMP4") != nil
        let mediaExtOK = MediaConverter.Target.m4aAudio.fileExtension == "m4a" && MediaConverter.Target.mp4.fileExtension == "mp4"
        check("media-convert", extractReg && mp4Reg && mediaExtOK,
            "extract=\(extractReg) mp4=\(mp4Reg) ext=\(mediaExtOK)")

        // Crop editor: command registered; cropped-copy naming appends " Cropped".
        let cropReg = commands.command("image.crop") != nil
        let cropNameOK = ImageCropper.croppedName(for: "shot.png") == "shot Cropped.png"
        check("image-crop", cropReg && cropNameOK, "registered=\(cropReg) name=\(cropNameOK)")

        // Remove Location (GPS privacy): command registered; a non-image reports no location (safe).
        let rlReg = commands.command("image.removeLocation") != nil
        let rlSafe = !MetadataCleaner.hasLocation(URL(fileURLWithPath: "/etc/hosts"))
        check("remove-location", rlReg && rlSafe, "registered=\(rlReg) safe=\(rlSafe)")

        // Metadata editor: command registered; Finder tags round-trip (set then clear) on a temp file.
        let meReg = commands.command("files.editMetadata") != nil
        var tagsRoundTrip = false
        let tagFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-smoke-tag-\(UUID().uuidString).txt")
        if (try? Data("x".utf8).write(to: tagFile)) != nil {
            try? FileMetadata.setTags(["SmokeTag"], on: tagFile)
            let set = FileMetadata.tags(of: tagFile) == ["SmokeTag"]
            try? FileMetadata.setTags([], on: tagFile)
            let cleared = FileMetadata.tags(of: tagFile).isEmpty
            tagsRoundTrip = set && cleared
            try? FileManager.default.removeItem(at: tagFile)
        }
        check("metadata-editor", meReg && tagsRoundTrip, "registered=\(meReg) tags=\(tagsRoundTrip)")

        // VS Code / Cursor: both editors present in the integration list; the bundled .vsix resolves
        // (so one-click Integrate has something to install).
        let vscodeEditors = EditorIntegration.all.filter { $0.id.hasPrefix("vscode-") }.count
        let vsixFound = VSCodeIntegration.bundledVSIX() != nil
        check("vscode-integration", vscodeEditors == 2 && vsixFound, "editors=\(vscodeEditors) vsix=\(vsixFound)")

        // Lazy tag decoration: listing a 2,000-entry folder must enqueue tag reads only for the
        // visible window, not all 2,000 (the O(total-entries) getxattr pass the perf audit flagged).
        let tagProbeDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-tagperf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tagProbeDir, withIntermediateDirectories: true)
        let tagProbeEntries = (0..<2000).map {
            FileEntry(name: "f\(String(format: "%04d", $0)).txt", isDirectory: false, size: 1, modificationDate: nil)
        }
        let tagEnqueued = FileListController().debugTagReadsEnqueued(
            listing: tagProbeEntries, in: tagProbeDir, visibleHeight: 400)
        try? FileManager.default.removeItem(at: tagProbeDir)
        check("tag-decoration-lazy", tagEnqueued > 0 && tagEnqueued < 200, "enqueued=\(tagEnqueued) of \(tagProbeEntries.count) visible-window")

        // Lazy semantic index: opening/navigating folders must not build the content-reading index
        // (it reads + embeds up to 5000 files); it builds only on first search. The app has launched
        // and navigated (home) but nothing has searched, so no folder is indexed.
        check("semantic-index-lazy", semanticSearch.cachedDirectory == nil,
            "cached=\(semanticSearch.cachedDirectory?.lastPathComponent ?? "nil")")

        // Demo workspace (first-run tour): the command is registered and build() produces a real,
        // navigable sample tree with the expected dual-pane starts.
        let demo = DemoWorkspace.build()
        let demoReg = commands.command("help.demoWorkspace") != nil
        let demoDirs = FileManager.default.fileExists(atPath: demo.leftStart.path)
            && FileManager.default.fileExists(atPath: demo.rightStart.path)
        check("demo-workspace", demoReg && demoDirs, "registered=\(demoReg) dirs=\(demoDirs)")

        // Trash Put-Back ledger: trashing a file records where it came from, and undo (Put Back)
        // restores it -- the recovery path users trust. Uses a temp file, restored then removed.
        let putBackProbe = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-putback-\(UUID().uuidString).txt")
        var putBackOK = false
        var putBackDetail = "no file"
        if (try? Data("x".utf8).write(to: putBackProbe)) != nil {
            performLocalTrash([putBackProbe])
            let recorded = trashOrigins.values.contains(putBackProbe.path)  // ledger maps trashed -> original
            let gone = !FileManager.default.fileExists(atPath: putBackProbe.path)
            if actionHistory.canUndo { actionHistory.undo() }  // Put Back
            let restored = FileManager.default.fileExists(atPath: putBackProbe.path)
            putBackOK = recorded && gone && restored
            putBackDetail = "recorded=\(recorded) gone=\(gone) restored=\(restored)"
            try? FileManager.default.removeItem(at: putBackProbe)  // clean up the restored temp
        }
        check("trash-putback-ledger", putBackOK, putBackDetail)

        // SFTP host-key check: a host we've never seen isn't pinned, so the first-connect prompt fires.
        let hostKeyUnknown = !HostKeyCheck.isKnown(host: "pathem-\(UUID().uuidString).invalid", port: 22)
        check("sftp-hostkey-check", hostKeyUnknown, "unknown host not pinned")

        // Out-drag of a text-like file (HTML) is a plain file URL with NO promise, so Messages/Mail
        // attach it instead of inlining its text; a binary (PNG) keeps its file promise (for browser
        // upload zones).
        let dragDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dragDir, withIntermediateDirectories: true)
        let htmlURL = dragDir.appendingPathComponent("page.html")
        let pngURL = dragDir.appendingPathComponent("pic.png")
        try? Data("<html><body>hi</body></html>".utf8).write(to: htmlURL)
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: pngURL)  // PNG magic; extension resolves the type
        let htmlNoPromise = FileDrag.isTextLike(htmlURL) && !(FileDrag.item(for: htmlURL) is NSFilePromiseProvider)
        let pngHasPromise = !FileDrag.isTextLike(pngURL) && FileDrag.item(for: pngURL) is NSFilePromiseProvider
        try? FileManager.default.removeItem(at: dragDir)
        check("drag-text-attaches", htmlNoPromise && pngHasPromise, "html-fileURL=\(htmlNoPromise) png-promise=\(pngHasPromise)")

        // Grouped duplicate resolver: keep one per set. A 3-file set queues 2, a 2-file set queues 1.
        func dupEntry(_ name: String, _ loc: String) -> FileEntry {
            FileEntry(name: name, isDirectory: false, size: 10, modificationDate: nil, location: loc)
        }
        let dupGroups = [
            DuplicateFinder.Group(hash: "a", files: [dupEntry("a1", "/x"), dupEntry("a2", "/y"), dupEntry("a3", "/z")]),
            DuplicateFinder.Group(hash: "b", files: [dupEntry("b1", "/x"), dupEntry("b2", "/y")]),
        ]
        let dupQueued = DuplicatesController().debugQueuedCount(groups: dupGroups)
        let dupReg = commands.command("files.findDuplicates") != nil
        check("duplicates-resolver", dupReg && dupQueued == 3, "registered=\(dupReg) queued=\(dupQueued) keep-one-per-set")

        // Match Finder: applying a mapped Finder value flips the matching Pathem pref and reports it;
        // a nil field is left untouched. In-memory only (applyFinderMatch doesn't persist), and reset
        // after so the real preferences file is never touched.
        let mfHidden = prefs.showHiddenByDefault
        let mfFolders = prefs.foldersFirst
        let mfChanges = applyFinderMatch(.init(showHidden: !mfHidden, foldersFirst: nil, defaultView: nil))
        let mfFlipped = prefs.showHiddenByDefault == !mfHidden
        let mfUntouched = prefs.foldersFirst == mfFolders  // nil field left alone
        prefs.showHiddenByDefault = mfHidden  // reset in memory (never persisted)
        check(
            "match-finder-applies", mfFlipped && mfUntouched && mfChanges.count == 1,
            "flipped=\(mfFlipped) untouched=\(mfUntouched) changes=\(mfChanges)")
        // Persistent folder-size cache: a recorded size is reused while the folder's mtime is
        // unchanged, and invalidated when it changes. In-memory store (nil fileURL) so the smoke
        // never writes the real cache file.
        let sizeStore = FolderSizeStore(cache: FolderSizeCache(), fileURL: nil)
        let szDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-size-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: szDir, withIntermediateDirectories: true)
        let szMtime = FolderSizeStore.mtimeKey(of: szDir)
        sizeStore.record(path: szDir.path, measurement: .init(bytes: 4096, complete: true), mtime: szMtime)
        let szHit = sizeStore.measurement(forPath: szDir.path, mtime: szMtime)?.bytes == 4096
        let szMissOnChange = sizeStore.measurement(forPath: szDir.path, mtime: szMtime + 1) == nil
        try? FileManager.default.removeItem(at: szDir)
        check("folder-size-cache", szHit && szMissOnChange, "hit=\(szHit) missOnChange=\(szMissOnChange)")
        // The sidebar tracks the current folder like Finder/Music: highlight the matching row,
        // deselect when the folder isn't a sidebar item.
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        sidebar.highlightFolder(homeURL)
        let tracksHome = sidebar.debugSelectedFolderURL?.standardizedFileURL == homeURL.standardizedFileURL
        sidebar.highlightFolder(URL(fileURLWithPath: "/System/Volumes/nope-not-a-sidebar-item"))
        let deselectsOffList = sidebar.debugSelectedFolderURL == nil
        check(
            "sidebar-tracks-current-folder", tracksHome && deselectsOffList,
            "home=\(tracksHome) deselect=\(deselectsOffList)")
        // Shrinking a listing must clamp the scroll back to the top, not strand the view
        // scrolled into empty space below the few remaining rows (the "panels scroll down
        // after a change" bug). Load a tall synthetic list, scroll to the bottom, shrink it
        // to two rows, and assert the offset returns to zero.
        let tallList = (0..<40).map {
            FileEntry(
                name: String(format: "row-%02d.txt", $0), isDirectory: false, size: 0, modificationDate: nil)
        }
        let shrink = FileListController()
        shrink.debugLayout(width: 300, height: 100)  // small viewport so the list overflows
        shrink.setEntries(tallList, preserveState: false)
        shrink.debugLayout(width: 300, height: 100)
        shrink.debugScrollToBottom()
        let scrolled = shrink.debugScrollOriginY()
        shrink.setEntries(Array(tallList.prefix(2)), preserveState: true)  // shrink to 2 rows
        let after = shrink.debugScrollOriginY()
        check(
            "scroll-clamps-on-shrink", scrolled > 0 && after == 0,
            "scrolled=\(Int(scrolled)) after=\(Int(after)) (want after=0)")
        // Embedded Settings: build the in-pane settings view (catches a crash in that path).
        let settingsView = settings.makeEmbedded(
            prefs: prefs, commands: commands.all.map { (id: $0.id, title: $0.title) },
            effective: keymap.bindings, gestures: gestureMap.bindings, updater: updater,
            terminal: .init(
                themes: TerminalTheme.presets.map(\.name), current: terminal.theme.name,
                follows: terminalFollows, onSelectTheme: { _ in }, onToggleFollows: { _ in }),
            onChange: { _ in }, onKeymapChange: { _ in }, onGestureChange: { _ in })
        check("settings-embeds", !settingsView.subviews.isEmpty, "\(settingsView.subviews.count) subviews")
        // Organize review sheet: build it with synthetic suggestions (a move and a trash)
        // so a crash in the row/detail layout is caught headlessly.
        let review = OrganizeReviewController(
            feedbackURL: FileManager.default.temporaryDirectory.appendingPathComponent("pathem-fb-smoke.json"))
        review.debugLoad([
            .init(file: URL(fileURLWithPath: "/tmp/a.png"), kind: .move(to: URL(fileURLWithPath: "/tmp/Images")),
                ruleID: "by-kind", rationale: "Image to Images", confidence: 0.8, size: 1234, accepted: true),
            .init(file: URL(fileURLWithPath: "/tmp/.DS_Store"), kind: .trash, ruleID: "junk",
                rationale: "System junk file", confidence: 0.9, size: 6, accepted: true),
        ])
        check("organize-review-builds", review.debugRowCount == 2, "\(review.debugRowCount) rows")
        // Cleanup panel (with its new detail pane) must construct without a layout crash.
        check("cleanup-builds", CleanupController().debugContentReady, "content ready")
        // The ambient download chip must render its suggestion text without crashing.
        let chip = DownloadSuggestionBar()
        chip.show(fileURL: URL(fileURLWithPath: "/tmp/invoice.pdf"), destinationName: "PDFs")
        check("download-chip-builds", chip.debugVisibleText?.contains("PDFs") == true, chip.debugVisibleText ?? "nil")
        // The transfer queue holds when paused and re-queues a failed job on retry.
        check("transfer-queue-pause-retry", TransferQueueController().debugPauseRetry(), "")
        // New Folder with Selection: create a folder, move items in, and undo back to the start.
        let nfwsDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-nfws-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: nfwsDir, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] { try? "x".write(to: nfwsDir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let nfwsFolder = (try? FileOperations.makeFolder(in: nfwsDir, baseName: "New Folder With Items")) ?? ""
        let nfwsOutcome = FileOperations.move(
            ["a.txt", "b.txt"], from: nfwsDir, to: nfwsDir.appendingPathComponent(nfwsFolder), onConflict: .keepBoth)
        let movedIn = FileManager.default.fileExists(
            atPath: nfwsDir.appendingPathComponent(nfwsFolder).appendingPathComponent("a.txt").path)
        FileOperations.undo(nfwsOutcome.performed)  // move back out
        _ = FileOperations.trash([nfwsFolder], in: nfwsDir)  // and remove the emptied folder
        let backOut = FileManager.default.fileExists(atPath: nfwsDir.appendingPathComponent("a.txt").path)
        check("new-folder-with-selection", !nfwsFolder.isEmpty && movedIn && backOut,
            "folder=\(nfwsFolder) movedIn=\(movedIn) undone=\(backOut)")
        try? FileManager.default.removeItem(at: nfwsDir)
        // The cursor-anchored confirmation popover builds its content without a layout crash, and
        // a non-Ask conflict default resolves without prompting.
        check("cursor-confirm-builds",
            cursorConfirm.debugBuildsController(buttons: ["Replace", "Keep Both", "Skip", "Cancel"]), "")
        check("conflict-default-maps",
            ConflictDefault.keepBoth.resolution == .keepBoth && ConflictDefault.ask.resolution == nil, "")
        // Verified copy: copying a file with verify on succeeds (SHA-256 matches) and lands.
        let vDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-verify-\(UUID().uuidString)")
        let vSrcDir = vDir.appendingPathComponent("src")
        let vDstDir = vDir.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: vSrcDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vDstDir, withIntermediateDirectories: true)
        let vSrc = vSrcDir.appendingPathComponent("v.txt")
        try? String(repeating: "payload ", count: 2000).write(to: vSrc, atomically: true, encoding: .utf8)
        let vOutcome = FileOperations.copy(urls: [vSrc], into: vDstDir, verify: true)
        let vOK = vOutcome.failures.isEmpty
            && FileManager.default.fileExists(atPath: vDstDir.appendingPathComponent("v.txt").path)
        check("verified-copy", vOK, "performed=\(vOutcome.performed.count) failures=\(vOutcome.failures.count)")
        try? FileManager.default.removeItem(at: vDir)
        // Arrange By: ungrouped is 1:1 items; grouping by kind adds section headers and keeps
        // every item, mapping each display row back to an entry.
        let gEntries = [
            FileEntry(name: "b.txt", isDirectory: false, size: 10, modificationDate: nil, location: nil),
            FileEntry(name: "afolder", isDirectory: true, size: 0, modificationDate: nil, location: nil),
            FileEntry(name: "c.txt", isDirectory: false, size: 10, modificationDate: nil, location: nil),
        ]
        let flat = FileGrouping.rows(gEntries, by: .none, now: Date())
        let grouped = FileGrouping.rows(gEntries, by: .kind, now: Date())
        func headers(_ r: [FileGrouping.Row]) -> Int { r.filter { if case .header = $0 { return true }; return false }.count }
        func items(_ r: [FileGrouping.Row]) -> Int { r.filter { if case .item = $0 { return true }; return false }.count }
        check("arrange-by-grouping",
            flat.count == 3 && headers(flat) == 0 && items(grouped) == 3 && headers(grouped) >= 2,
            "flat=\(flat.count) groupedHeaders=\(headers(grouped)) groupedItems=\(items(grouped))")
        // And against the real list view: grouping + selection maps back to the right entry.
        check("arrange-by-selection", leftTabs.activePane?.debugGroupedSelectionRoundTrips() ?? true, "")
        // Collapsible sections: collapsing a group hides its items but keeps the header, and
        // re-expanding restores the rows.
        check("collapsible-sections", leftTabs.activePane?.debugCollapseHidesItems() ?? true, "")
        // External commands: the manager + output panel construct, and a command runs via the engine.
        _ = ExternalCommandsController()
        _ = ExternalCommandOutputController()
        let ecOut = ExternalCommandRunner.run(
            ExternalCommand(id: "smoke", name: "echo", command: "echo ok"),
            files: [], directory: FileManager.default.temporaryDirectory)
        check("external-command-runs", ecOut.succeeded && ecOut.text.contains("ok"), "exit=\(ecOut.exitCode)")
        // Undo history: two path-disjoint actions; the older is independently undoable, and a
        // selective undo runs just its reverse and enables redo.
        let history = ActionHistory()
        var undoLog: [String] = []
        history.record(name: "A", footprint: ["/a"], undoFootprint: ["/a"]) {
            undoLog.append("undoA")
            history.record(name: "A'", footprint: ["/a"], undoFootprint: ["/a"], perform: {})
        }
        history.record(name: "B", footprint: ["/b"], undoFootprint: ["/b"]) {
            undoLog.append("undoB")
            history.record(name: "B'", footprint: ["/b"], undoFootprint: ["/b"], perform: {})
        }
        let indepA = history.isIndependentlyUndoable(at: 0)
        let didUndoA = history.undo(at: 0)
        check("undo-history-selective", indepA && didUndoA && undoLog == ["undoA"] && history.canRedo,
            "indep=\(indepA) undid=\(didUndoA) log=\(undoLog) canRedo=\(history.canRedo)")
        // The real file-op undo path: move a file, register it in the live history, then undo it.
        let uDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-undo-\(UUID().uuidString)")
        let uSrc = uDir.appendingPathComponent("src")
        let uDst = uDir.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: uSrc, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: uDst, withIntermediateDirectories: true)
        try? "x".write(to: uSrc.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let uOutcome = FileOperations.move(["f.txt"], from: uSrc, to: uDst, onConflict: .keepBoth)
        registerUndo(uOutcome.performed, actionName: "Move")
        let movedOK = FileManager.default.fileExists(atPath: uDst.appendingPathComponent("f.txt").path)
        actionHistory.undo()  // reverses the move
        let undoneOK = FileManager.default.fileExists(atPath: uSrc.appendingPathComponent("f.txt").path)
            && !FileManager.default.fileExists(atPath: uDst.appendingPathComponent("f.txt").path)
        check("undo-file-move", movedOK && undoneOK, "moved=\(movedOK) undone=\(undoneOK)")
        try? FileManager.default.removeItem(at: uDir)
        // The new superuser/developer panels must construct without a layout crash.
        _ = DiffViewerController()
        let panelsOK =
            XattrController().debugRowCount == 0 && BulkAttributesController().debugContentReady
            && AutomationRulesController().debugContentReady
        check("aux-panels-build", panelsOK, "diff/xattr/attrs/automation")
        // End-to-end ambient path: point Downloads at a temp dir, drop a file, run one change
        // pass, and confirm the chip offers to move it (catches wiring bugs the unit tests can't).
        let dlDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: dlDir.appendingPathComponent("receipt.pdf"))
        downloadSuggestions.debugRunCheck(  // empty seed => receipt.pdf reads as newly arrived
            folder: dlDir, seedKnown: [], feedbackURL: Self.organizeFeedbackURL)
        check(
            "download-suggestion-fires", downloadSuggestions.debugChipText?.contains("receipt.pdf") == true,
            downloadSuggestions.debugChipText ?? "no chip")
        downloadSuggestions.debugReset()
        try? FileManager.default.removeItem(at: dlDir)
        // Teardown-leak guard: the Downloads/automation watchers self-retain via their FSEvents
        // stream, so a window close must stop them (BVC.teardown now does). Verify the stop
        // mechanism itself on a fresh controller so it can't silently regress.
        let leakProbe = DownloadSuggestionsController()
        leakProbe.start(feedbackURL: nil)
        let watchingAfterStart = leakProbe.debugIsWatching
        leakProbe.stop()
        check(
            "download-watcher-stops", watchingAfterStart && !leakProbe.debugIsWatching,
            "start=\(watchingAfterStart) afterStop=\(leakProbe.debugIsWatching)")
        // The quick-actions bar geometry must place the bar next to the selection, not at a
        // fixed spot (verified as pure math; the live layout is confirmed visually).
        let qbPane = NSRect(x: 0, y: 0, width: 500, height: 700)
        let qbSel = NSRect(x: 100, y: 400, width: 200, height: 24)
        let qbOrigin = Self.quickBarOrigin(
            barSize: NSSize(width: 240, height: 38), selection: qbSel, pane: qbPane, margin: 8)
        let qbMidY = qbOrigin.y + 19
        check(
            "quickbar-near-selection", abs(qbMidY - qbSel.midY) < 80,
            "bar midY \(Int(qbMidY)) vs selection \(Int(qbSel.midY))")
        // The View-in-pane quick buttons appear only for a single viewable (PDF/image) selection.
        quickBar.update(selectionCount: 1, isViewable: true)
        let qbViewShown = quickBar.debugViewButtonsShown
        quickBar.update(selectionCount: 1, isViewable: false)
        let qbViewHidden = !quickBar.debugViewButtonsShown
        check(
            "quickbar-view-buttons-type-aware", qbViewShown && qbViewHidden,
            "viewable-shows=\(qbViewShown) nonviewable-hides=\(qbViewHidden)")
        updateQuickActions()  // restore real state
        // Column view instead pins the bar to the pane's bottom (clear of the drilled
        // columns), so a no-selection bottom placement sits lower than the top-center one.
        let qbBottom = Self.quickBarOrigin(
            barSize: NSSize(width: 240, height: 38), selection: nil, pane: qbPane, margin: 8,
            noSelectionAtBottom: true)
        let qbTop = Self.quickBarOrigin(
            barSize: NSSize(width: 240, height: 38), selection: nil, pane: qbPane, margin: 8,
            noSelectionAtBottom: false)
        check(
            "quickbar-column-bottom", qbBottom.y < qbTop.y,
            "bottom.y=\(Int(qbBottom.y)) top.y=\(Int(qbTop.y))")
        // Switching a pane's view mode must not move the split divider (durable ratio constraint).
        let beforeRight = rightTabs.containerView.frame.width
        let originalMode = rightTabs.activePane?.viewMode ?? .list
        rightTabs.activePane?.setViewMode(.gallery)
        view.layoutSubtreeIfNeeded()
        let afterRight = rightTabs.containerView.frame.width
        rightTabs.activePane?.setViewMode(originalMode)  // restore
        check(
            "split-stable-on-view-switch", abs(beforeRight - afterRight) < 5,
            "right pane \(Int(beforeRight)) -> \(Int(afterRight))")
        // Dragging out must advertise both file URLs (modern apps) and legacy filenames (VMware
        // etc.) on the same pasteboard; adding the legacy type must not drop the file URLs.
        let scratch = NSPasteboard(name: NSPasteboard.Name("com.scarcrux.pathem.dragcheck"))
        scratch.clearContents()
        let dragURLs = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        scratch.writeObjects(dragURLs.map { $0 as NSURL })
        FileDrag.addLegacyFilenames(dragURLs, to: scratch)
        let keepsFileURL = scratch.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let filenames = scratch.propertyList(forType: FileDrag.filenamesType) as? [String]
        check(
            "drag-has-legacy-filenames", keepsFileURL && filenames == dragURLs.map(\.path),
            "fileURL=\(keepsFileURL) names=\(filenames ?? [])")
        // A dragged non-text file must also advertise a file PROMISE (alongside its file URL), or
        // browser upload zones and sandboxed apps -- which materialize the promise into
        // DataTransfer.files -- silently reject the drop. (Text-like files intentionally have no
        // promise; see drag-text-attaches.)
        let promiseScratch = NSPasteboard(name: NSPasteboard.Name("com.scarcrux.pathem.promisecheck"))
        promiseScratch.clearContents()
        promiseScratch.writeObjects([FileDrag.item(for: URL(fileURLWithPath: "/tmp/a.png"))])
        let promiseType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        let hasPromise = promiseScratch.types?.contains(promiseType) ?? false
        let promiseFileURL = promiseScratch.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        check(
            "drag-has-file-promise", hasPromise && promiseFileURL,
            "promise=\(hasPromise) fileURL=\(promiseFileURL)")
        // The promise delegate is pulled OFF the main thread by other apps (Messages fetches it
        // via file-provider XPC on a FileCoordination queue). Exercise it off-main: if the
        // delegate methods were main-actor-isolated the Swift concurrency check would trap the
        // whole process, so this also fails to compile if the `nonisolated` markers regress.
        let promiseSrc = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-promise-\(UUID().uuidString).txt")
        try? "promise payload".write(to: promiseSrc, atomically: true, encoding: .utf8)
        // Reproduce the Messages path: Foundation hands the delegate a fresh, plain provider
        // (not our FileDragItem) carrying the source only in userInfo. If the delegate can't
        // resolve the source from userInfo it writes nothing and the drop silently does nothing.
        let promiseItem = NSFilePromiseProvider(
            fileType: "public.plain-text", delegate: FilePromiseFulfiller.shared)
        promiseItem.userInfo = promiseSrc
        let fulfiller = FilePromiseFulfiller.shared
        let promiseDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-promise-dst-\(UUID().uuidString)")
            .appendingPathComponent(promiseSrc.lastPathComponent)
        try? FileManager.default.createDirectory(
            at: promiseDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let promiseBox = SmokePromiseResult()
        let promiseSem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = fulfiller.operationQueue(for: promiseItem)  // the exact call that trapped
            promiseBox.name = fulfiller.filePromiseProvider(promiseItem, fileNameForType: "public.plain-text")
            // Actually fulfill the promise, exactly as a receiver (Messages) triggers it.
            fulfiller.filePromiseProvider(promiseItem, writePromiseTo: promiseDest) { err in
                promiseBox.error = err
                promiseSem.signal()
            }
        }
        promiseSem.wait()
        let wrote = promiseBox.error == nil && FileManager.default.fileExists(atPath: promiseDest.path)
        check("promise-fulfills-offmain", promiseBox.name == promiseSrc.lastPathComponent && wrote,
            "name=\(promiseBox.name) wrote=\(wrote) err=\(promiseBox.error.map { "\($0)" } ?? "nil")")
        try? FileManager.default.removeItem(at: promiseSrc)
        try? FileManager.default.removeItem(at: promiseDest.deletingLastPathComponent())
        // Dragging a FOLDER out must land the whole tree, not a truncated stub. A folder drags as a
        // plain file URL with NO promise (a folder promise makes Finder pull a truncated stub); a
        // regular file still advertises a promise (browser upload zones need it). Also confirm the
        // fulfiller copies a directory recursively, for any receiver that does pull a promise.
        let dirSrc = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-dragdir-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dirSrc.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? "one".write(to: dirSrc.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? String(repeating: "x", count: 5000).write(
            to: dirSrc.appendingPathComponent("sub/big.txt"), atomically: true, encoding: .utf8)
        let dirProvider = NSFilePromiseProvider(fileType: "public.folder", delegate: FilePromiseFulfiller.shared)
        dirProvider.userInfo = dirSrc
        let dirDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-dragdst-\(UUID().uuidString)")
            .appendingPathComponent(dirSrc.lastPathComponent)
        try? FileManager.default.createDirectory(
            at: dirDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dirBox = SmokePromiseResult()
        let dirSem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            fulfiller.filePromiseProvider(dirProvider, writePromiseTo: dirDest) { err in
                dirBox.error = err
                dirSem.signal()
            }
        }
        dirSem.wait()
        let copiedBigSize =
            ((try? FileManager.default.attributesOfItem(atPath: dirDest.appendingPathComponent("sub/big.txt").path))?[.size]
                as? Int) ?? 0
        let treeCopied =
            dirBox.error == nil
            && FileManager.default.fileExists(atPath: dirDest.appendingPathComponent("a.txt").path)
            && copiedBigSize == 5000
        let promiseContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        func advertised(_ url: URL) -> (fileURL: Bool, promise: Bool) {
            let pb = NSPasteboard(name: NSPasteboard.Name("com.scarcrux.pathem.dragw-\(UUID().uuidString)"))
            pb.clearContents()
            pb.writeObjects([FileDrag.item(for: url)])
            let hasURL = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            return (hasURL, pb.types?.contains(promiseContentType) ?? false)
        }
        let dirAd = advertised(dirSrc)
        let fileAd = advertised(dirSrc.appendingPathComponent("pic.png"))  // a non-text file: keeps its promise
        try? FileManager.default.removeItem(at: dirSrc)
        try? FileManager.default.removeItem(at: dirDest.deletingLastPathComponent())
        check(
            "folder-drag-whole-tree-no-promise",
            treeCopied && dirAd.fileURL && !dirAd.promise && fileAd.fileURL && fileAd.promise,
            "tree=\(treeCopied) big=\(copiedBigSize) dir(url=\(dirAd.fileURL),promise=\(dirAd.promise)) file(url=\(fileAd.fileURL),promise=\(fileAd.promise))")
        // Get Info: presenting the inspector builds every field (metadata reads, open-with,
        // toggles) without crashing, and populates a reasonable number of them.
        let inspector = InfoInspectorController()
        let infoTmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-info-\(UUID().uuidString).txt")
        try? "hi".write(to: infoTmp, atomically: true, encoding: .utf8)
        inspector.present(urls: [infoTmp], over: nil)
        check("get-info-populates", inspector.debugFieldCount >= 5, "\(inspector.debugFieldCount) fields")
        inspector.debugClose()
        try? FileManager.default.removeItem(at: infoTmp)
        // Semantic dedup + AI: the new commands are registered, clustering is crash-safe on empty
        // input, and the AI availability probe returns a defined value (whatever this Mac reports).
        let cmdIDs = Set(commands.all.map(\.id))
        check("ai-commands-registered",
            cmdIDs.isSuperset(of: ["files.findSimilarNames", "ai.renameSelection", "ai.summarizeFolder"]),
            "have=\(["files.findSimilarNames", "ai.renameSelection", "ai.summarizeFolder"].filter(cmdIDs.contains).count)/3")
        check("semantic-dedup-empty-safe", SemanticDedup.similarGroups([]).isEmpty, "no groups for no files")
        check("ai-availability-defined", AIAssistant.availability.reason.isEmpty == AIAssistant.isAvailable,
            "availability=\(AIAssistant.availability) reason=\"\(AIAssistant.availability.reason)\"")
        // Multi-window: the primary is registered, the window commands exist, and a second browser
        // constructs as an independent (non-persisting) session so it can't clobber the primary's.
        check("window-commands-registered", cmdIDs.isSuperset(of: ["window.new", "window.moveTabToNew"]),
            "have=\(["window.new", "window.moveTabToNew"].filter(cmdIDs.contains).count)/2")
        let secondary = BrowserViewController(start: FileManager.default.homeDirectoryForCurrentUser, persistsSession: false)
        let interactive = BrowserViewController(start: FileManager.default.homeDirectoryForCurrentUser)  // default: owns the session
        check("new-window-independent-session",
            !secondary.persistsSession && interactive.persistsSession && WindowManager.shared.windowCount >= 1,
            "secondaryPersists=\(secondary.persistsSession) interactivePersists=\(interactive.persistsSession) windows=\(WindowManager.shared.windowCount)")
        // An automation launch (this smoke run) must be detected as such, so it never persists over
        // the user's real session.json -- the bug where test runs left the app reopening on /tmp.
        check("automation-launch-detected", PathemApp.isAutomationLaunch && !self.persistsSession,
            "isAutomation=\(PathemApp.isAutomationLaunch) primaryPersists=\(self.persistsSession)")
        // Duplicate Tab (the tab right-click action): a new tab opens at the same folder. Close it
        // again to leave the tab set as it was.
        if let dupURL = leftTabs.activePane?.currentURL {
            let beforeTabs = leftTabs.tabFolders.count
            leftTabs.openTab(at: dupURL)
            let dupOK = leftTabs.tabFolders.count == beforeTabs + 1 && leftTabs.tabFolders.last == dupURL.path
            leftTabs.closeActiveTab()  // the duplicate is the focused/last tab
            check("tab-duplicate", dupOK && leftTabs.tabFolders.count == beforeTabs,
                "before=\(beforeTabs) dupedAtSame=\(dupOK) restored=\(leftTabs.tabFolders.count)")
        }
        // Slideshow: the command is registered and the controller starts inactive (a headless
        // smoke must not pop a full-screen window, so we don't call start()).
        check("slideshow-ready", cmdIDs.contains("view.slideshow") && !slideshow.isActive,
            "registered=\(cmdIDs.contains("view.slideshow")) active=\(slideshow.isActive)")
        // Create PDF: two images combine into a real 2-page PDF.
        let pdfDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-pdf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        var pdfImages: [URL] = []
        for i in 0..<2 {
            let image = NSImage(size: NSSize(width: 60, height: 40))
            image.lockFocus()
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 60, height: 40).fill()
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
                let url = pdfDir.appendingPathComponent("p\(i).png")
                try? png.write(to: url)
                pdfImages.append(url)
            }
        }
        let pdfOut = BrowserViewController.buildPDF(from: pdfImages, in: pdfDir)
        let pdfPages = pdfOut.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
        check("create-pdf-builds", pdfPages == 2, "pages=\(pdfPages)")
        // Markup: draw a stroke over an image and flatten to a valid same-size PNG.
        let mkFile = pdfDir.appendingPathComponent("markup-src.png")
        let mkImage = NSImage(size: NSSize(width: 80, height: 60))
        mkImage.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 80, height: 60).fill(); mkImage.unlockFocus()
        if let tiff = mkImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: mkFile)
        }
        let mkOut = markupController.debugMarkupAndSave(mkFile)
        let mkSize = mkOut.flatMap { NSImage(contentsOf: $0)?.size.width } ?? 0
        check("markup-flattens", cmdIDs.contains("image.markup") && mkOut != nil && mkSize >= 80,
            "registered=\(cmdIDs.contains("image.markup")) out=\(mkOut != nil) width=\(Int(mkSize))")
        try? FileManager.default.removeItem(at: pdfDir)
        // Show Original: a symlink resolves to its target; a plain file resolves to nil.
        let soDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-showorig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: soDir, withIntermediateDirectories: true)
        let soTarget = soDir.appendingPathComponent("target.txt")
        let soLink = soDir.appendingPathComponent("link.txt")
        try? "x".write(to: soTarget, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: soLink, withDestinationURL: soTarget)
        let resolvedLink = BrowserViewController.resolveOriginal(of: soLink)
        let resolvedPlain = BrowserViewController.resolveOriginal(of: soTarget)
        check("show-original-resolves", resolvedLink?.lastPathComponent == "target.txt" && resolvedPlain == nil,
            "link=\(resolvedLink?.lastPathComponent ?? "nil") plain=\(resolvedPlain?.lastPathComponent ?? "nil")")
        try? FileManager.default.removeItem(at: soDir)
        // Batch metadata + server: the new commands are registered, and the Finder-comment writer
        // round-trips (set, read back, clear) through the engine.
        check("batch-commands-registered",
            cmdIDs.isSuperset(of: ["files.setFinderComment", "files.connectToServer"]),
            "have=\(["files.setFinderComment", "files.connectToServer"].filter(cmdIDs.contains).count)/2")
        // Remote bookmarks: the command is registered and a bookmark survives a save/jump
        // round-trip on a connection (mirrors what addBookmark writes into the store).
        var bmConn = RemoteConnection(name: "Site", proto: .sftp, host: "h.example.com")
        bmConn.bookmarks.append(RemoteBookmark(name: "Logs", remotePath: "/var/log"))
        let bmData = (try? JSONEncoder().encode(bmConn)).flatMap {
            try? JSONDecoder().decode(RemoteConnection.self, from: $0)
        }
        check("remote-bookmarks",
            cmdIDs.contains("files.addBookmark") && bmData?.bookmarks.first?.remotePath == "/var/log",
            "cmd=\(cmdIDs.contains("files.addBookmark")) path=\(bmData?.bookmarks.first?.remotePath ?? "nil")")
        // Sync browsing: the command is registered and a relative descend on one pane
        // maps onto the other pane's parallel tree (delta mirroring, not same-path lock).
        let syncDescend = SyncBrowse.mirroredPath(
            driverFrom: "/a/projA", driverTo: "/a/projA/src", otherAt: "/a/projB")
        let syncAscend = SyncBrowse.mirroredPath(
            driverFrom: "/a/projA/src", driverTo: "/a/projA", otherAt: "/a/projB/src")
        check("sync-browse-delta",
            cmdIDs.contains("view.syncBrowsing") && syncDescend == "/a/projB/src"
                && syncAscend == "/a/projB",
            "cmd=\(cmdIDs.contains("view.syncBrowsing")) descend=\(syncDescend ?? "nil") ascend=\(syncAscend ?? "nil")")
        // Azure Blob: the protocol dispatches to its provider and the Shared Key signer
        // produces a signature (correctness is unit-tested against an HMAC vector).
        let azureProvider = RemoteProviders.make(for: .azure) is AzureBlobProvider
        let azureSig = AzureSharedKey.signature(
            key: Data("Jefe".utf8).base64EncodedString(), stringToSign: "what do ya want for nothing?")
        check("azure-blob-backend",
            azureProvider && RemoteConnection.Proto.allCases.contains(.azure) && azureSig != nil,
            "provider=\(azureProvider) signer=\(azureSig != nil)")
        // Cloud folder badges: a cloud folder's icon is decorated with a service glyph; a
        // plain folder's is returned untouched (same instance).
        let homeDir = NSHomeDirectory()
        let cloudDir = URL(fileURLWithPath: homeDir).appendingPathComponent("Library/CloudStorage")
        let baseIcon = NSWorkspace.shared.icon(forFile: "/")
        let cloudFolder = FileEntry(name: "GoogleDrive-x@y.com", isDirectory: true, size: 0, modificationDate: nil)
        let plainFolder = FileEntry(name: "Documents", isDirectory: true, size: 0, modificationDate: nil)
        let badged = CloudBadge.decorate(baseIcon, for: cloudFolder, in: cloudDir)
        let plain = CloudBadge.decorate(baseIcon, for: plainFolder, in: URL(fileURLWithPath: homeDir).appendingPathComponent("Code"))
        check("cloud-folder-badge",
            badged !== baseIcon && plain === baseIcon
                && CloudLocation.service(forFolderAt: cloudDir.appendingPathComponent("GoogleDrive-x@y.com").path, home: homeDir) == .googleDrive,
            "badged=\(badged !== baseIcon) plainUntouched=\(plain === baseIcon)")
        // Context menu editor: a custom order reorders the right-click menu, and hiding drops
        // an item. Build a menu with copy first and Rename hidden, then read it back.
        let cmenu = FileContextMenuController()
        cmenu.hiddenItems = ["files.rename"]
        cmenu.menuOrder = ["files.copy", "files.open"]
        let cmenuCommands = cmenu.menu.items.compactMap { $0.representedObject as? String }
        check("context-menu-reorder",
            Array(cmenuCommands.prefix(2)) == ["files.copy", "files.open"]
                && !cmenuCommands.contains("files.rename"),
            "first=\(Array(cmenuCommands.prefix(2))) hidRename=\(!cmenuCommands.contains("files.rename"))")
        // Color rules (labels): a matching rule yields a color/font; a non-match yields nil.
        let ruleSet = ColorRules(rules: [
            ColorRule(field: .ext, op: .isAnyOf, value: "log", colorHex: "#FF0000", bold: true)
        ])
        let logStyle = FileColorStyle.style(
            for: FileEntry(name: "a.log", isDirectory: false, size: 1, modificationDate: nil),
            rules: ruleSet, baseFont: .systemFont(ofSize: 13))
        let txtStyle = FileColorStyle.style(
            for: FileEntry(name: "a.txt", isDirectory: false, size: 1, modificationDate: nil),
            rules: ruleSet, baseFont: .systemFont(ofSize: 13))
        check("color-rules", logStyle?.color != nil && txtStyle == nil,
            "matched=\(logStyle?.color != nil) unmatched=\(txtStyle == nil)")
        // Custom toolbar buttons: the customize palette exposes every registry command (not
        // just the curated catalog), so any command can be dragged onto the toolbar.
        let paletteIDs = Set(toolbarAllowedItemIdentifiers(NSToolbar(identifier: "smoke")).map(\.rawValue))
        check("toolbar-any-command",
            paletteIDs.contains(Self.toolbarCmdPrefix + "view.syncBrowsing")
                && paletteIDs.count > Self.toolbarCatalog.count + 3,
            "palette=\(paletteIDs.count) catalog=\(Self.toolbarCatalog.count)")
        // Clean-uninstall + folder handler: the reset command is registered (never invoked
        // here -- it would wipe data), and the folder-default query answers without crashing.
        check("uninstall-hooks",
            cmdIDs.contains("app.resetData") && (FolderHandler.isPathem || !FolderHandler.isPathem),
            "reset=\(cmdIDs.contains("app.resetData"))")
        let fcFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-fc-\(UUID().uuidString).txt")
        try? "x".write(to: fcFile, atomically: true, encoding: .utf8)
        try? FileMetadata.setFinderComment("smoke note", on: fcFile)
        let fcRead = FileMetadata.finderComment(of: fcFile)
        try? FileMetadata.setFinderComment("", on: fcFile)
        let fcCleared = FileMetadata.finderComment(of: fcFile) == nil
        check("finder-comment-roundtrips", fcRead == "smoke note" && fcCleared, "read=\(fcRead ?? "nil") cleared=\(fcCleared)")
        try? FileManager.default.removeItem(at: fcFile)
        // ACL editor: the command is registered, the panel constructs, and the engine adds then
        // removes an entry on a real file (no privileges needed for your own file).
        _ = ACLEditorController()
        let aclFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-acl-\(UUID().uuidString).txt")
        try? "x".write(to: aclFile, atomically: true, encoding: .utf8)
        let added = ACLEditor.add(principal: NSUserName(), allow: true, permissions: ["read"], to: aclFile) == nil
        let listed = FileMetadata.aclEntries(of: aclFile)?.contains { $0.contains(NSUserName()) } ?? false
        let removed = ACLEditor.removeEntry(at: 0, from: aclFile) == nil && FileMetadata.aclEntries(of: aclFile) == nil
        check("acl-edit-roundtrips", cmdIDs.contains("files.editACL") && added && listed && removed,
            "registered=\(cmdIDs.contains("files.editACL")) added=\(added) listed=\(listed) removed=\(removed)")
        try? FileManager.default.removeItem(at: aclFile)
        // Ownership: change-owner command registered, the sudo command builds correctly, and a
        // change-group applies without root (setting the file's own group is a valid no-op).
        let ownFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-own-\(UUID().uuidString).txt")
        try? "x".write(to: ownFile, atomically: true, encoding: .utf8)
        let chownCmd = OwnershipEditor.sudoChownCommand(owner: "bob", group: "staff", recursive: false, paths: ["/tmp/a b"])
        let group = OwnershipEditor.read(ownFile)?.group ?? ""
        let grpOK = BulkAttributes.apply(.init(groupOwnerName: group), to: [ownFile]).failures.isEmpty && !group.isEmpty
        check("ownership-tools",
            cmdIDs.contains("files.changeOwner") && chownCmd == "sudo chown 'bob:staff' '/tmp/a b'" && grpOK,
            "registered=\(cmdIDs.contains("files.changeOwner")) cmd=\(chownCmd == "sudo chown 'bob:staff' '/tmp/a b'") group=\(grpOK)")
        try? FileManager.default.removeItem(at: ownFile)
        // Custom icon: the commands register and NSWorkspace applies then clears a custom icon.
        let iconDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-icon-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
        let customImage = NSImage(size: NSSize(width: 32, height: 32))
        customImage.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); customImage.unlockFocus()
        let iconSet = NSWorkspace.shared.setIcon(customImage, forFile: iconDir.path, options: [])
        NSWorkspace.shared.setIcon(nil, forFile: iconDir.path, options: [])
        check("custom-icon",
            cmdIDs.isSuperset(of: ["files.setCustomIcon", "files.removeCustomIcon"]) && iconSet,
            "registered=\(cmdIDs.isSuperset(of: ["files.setCustomIcon", "files.removeCustomIcon"])) set=\(iconSet)")
        try? FileManager.default.removeItem(at: iconDir)
        // Skinning: hex parsing, preset lookup, and an accent apply (restored afterward so the
        // running window keeps its configured skin).
        let parsedAccent = ThemeManager.color(fromHex: "#BD93F9")
        let emptyParse = ThemeManager.color(fromHex: "")
        let presetName = ThemePreset.matching(accentHex: "#BD93F9", backgroundHex: "#282A36", appearance: .dark)?.name
        ThemeManager.shared.apply(accentHex: "#FF0000", windowTintHex: "")
        let accentApplied = ThemeManager.shared.customAccent != nil
        ThemeManager.shared.apply(accentHex: prefs.accentColorHex, windowTintHex: prefs.windowTintHex)  // restore
        check("skinning-applies",
            parsedAccent != nil && emptyParse == nil && presetName == "Dracula" && accentApplied,
            "parsed=\(parsedAccent != nil) empty=\(emptyParse == nil) preset=\(presetName ?? "nil") applied=\(accentApplied)")
        // Folder backgrounds: the per-folder store round-trips (set, read, clear).
        check("folder-background-roundtrips", debugFolderBackgroundRoundTrips(), "")
        // Icon sets: a themed set renders an icon; "System" returns nil (use the OS icon).
        let sampleFolder = FileEntry(name: "docs", isDirectory: true, size: 0, modificationDate: nil)
        IconSetManager.shared.setCurrent(named: "Vivid")
        let themedIcon = IconSetManager.shared.icon(for: sampleFolder)
        IconSetManager.shared.setCurrent(named: "System")
        let systemIcon = IconSetManager.shared.icon(for: sampleFolder)
        IconSetManager.shared.setCurrent(named: prefs.iconSetName)  // restore
        check("icon-set-renders", themedIcon != nil && (themedIcon?.size.width ?? 0) > 0 && systemIcon == nil,
            "themed=\(themedIcon != nil) system=\(systemIcon == nil)")
        // Icon-view grouping: sections cover every entry and a selection maps back through the
        // section<->entry mapping.
        let gridGroup = IconCollectionController(gallery: false)
        gridGroup.directoryURL = URL(fileURLWithPath: "/tmp")
        gridGroup.setEntries([
            FileEntry(name: "b.txt", isDirectory: false, size: 10, modificationDate: nil),
            FileEntry(name: "afolder", isDirectory: true, size: 0, modificationDate: nil),
            FileEntry(name: "c.txt", isDirectory: false, size: 10, modificationDate: nil),
        ], preserveState: false)
        check("icon-view-grouping", gridGroup.debugGroupRoundTrips(), "")
        // Flat / recursive view: the command is registered and the enumerator flattens a subtree
        // (a nested file appears with its own subfolder location).
        let flatDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-flat-\(UUID().uuidString)")
        let flatSub = flatDir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: flatSub, withIntermediateDirectories: true)
        try? "x".write(to: flatDir.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try? "y".write(to: flatSub.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        let flatResult = FlatEnumerator.entries(of: flatDir, includeFolders: true)
        let hasDeep = flatResult.entries.contains { $0.name == "deep.txt" && ($0.location?.contains("sub") ?? false) }
        let hasTop = flatResult.entries.contains { $0.name == "top.txt" }
        check("flatten-folder", cmdIDs.contains("view.flattenFolder") && hasDeep && hasTop,
            "registered=\(cmdIDs.contains("view.flattenFolder")) deep=\(hasDeep) top=\(hasTop)")
        try? FileManager.default.removeItem(at: flatDir)
        // Tree view: the mode is registered, and the outline controller exposes its entries and a
        // location-aware selection (so file ops resolve to the real path).
        let tree = TreeOutlineController()
        tree.directoryURL = URL(fileURLWithPath: "/tmp")
        tree.setEntries([
            FileEntry(name: "afolder", isDirectory: true, size: 0, modificationDate: nil),
            FileEntry(name: "b.txt", isDirectory: false, size: 10, modificationDate: nil),
        ], preserveState: false)
        tree.select(name: "b.txt")
        let selected = tree.selectedEntries.first
        check("tree-view",
            cmdIDs.contains("view.asTree") && tree.entries.count == 2
                && selected?.name == "b.txt" && selected?.location == "/tmp",
            "registered=\(cmdIDs.contains("view.asTree")) entries=\(tree.entries.count) sel=\(selected?.name ?? "nil") loc=\(selected?.location ?? "nil")")
        // Commander mode: registered, and toggling shows then hides the bar.
        let commanderShown = debugToggleCommander()
        let commanderHidden = !debugToggleCommander()
        check("commander-mode", cmdIDs.contains("commander.toggle") && commanderShown && commanderHidden,
            "registered=\(cmdIDs.contains("commander.toggle")) shown=\(commanderShown) hidden=\(commanderHidden)")
        // Saved view presets: the store saves/replaces by name and round-trips the captured format,
        // and the save command is registered.
        var presetStore = ViewPresets.default
        presetStore.save(.init(name: "Photos", format: .init(viewMode: .icon, groupKey: .kind)))
        presetStore.save(.init(name: "Photos", format: .init(viewMode: .gallery, groupKey: .none)))  // replace by name
        let savedPreset = presetStore.presets.first { $0.name == "Photos" }
        check("view-presets",
            cmdIDs.contains("view.saveViewPreset") && presetStore.presets.count == 1
                && savedPreset?.format.viewMode == .gallery,
            "registered=\(cmdIDs.contains("view.saveViewPreset")) count=\(presetStore.presets.count) mode=\(savedPreset?.format.viewMode.rawValue ?? "nil")")
        // Vim navigation: the command is registered and j/k selection movement steps the selection.
        leftTabs.activePane?.selectFirst()
        let vimFirst = leftTabs.activePane?.selectedEntries.first?.name
        leftTabs.activePane?.moveSelection(by: 1)
        let vimSecond = leftTabs.activePane?.selectedEntries.first?.name
        check("vim-navigation",
            cmdIDs.contains("nav.vimMode") && vimFirst != nil && vimSecond != nil && vimFirst != vimSecond,
            "registered=\(cmdIDs.contains("nav.vimMode")) first=\(vimFirst ?? "nil") second=\(vimSecond ?? "nil")")
        // Open with Pathem / Services: openExternalFolder navigates the active pane. (Last check,
        // since it changes the active folder.)
        let openDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-open-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: openDir, withIntermediateDirectories: true)
        openExternalFolder(openDir)
        let navigated = activePane?.currentURL.standardizedFileURL == openDir.standardizedFileURL
        check("open-external-folder", navigated, "at=\(activePane?.currentURL.lastPathComponent ?? "nil")")
        // Reveal (pathem reveal / the Reveal in Pathem Service): lands in the item's PARENT, not
        // inside it -- the distinguishing behavior from Open. (Selection is applied async, so only
        // the navigation target is asserted here.)
        let revealParent = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-reveal-\(UUID().uuidString)")
        let revealChild = revealParent.appendingPathComponent("target-item")
        try? FileManager.default.createDirectory(at: revealChild, withIntermediateDirectories: true)
        revealExternalItem(revealChild)
        check("reveal-external-navigates-to-parent",
            activePane?.currentURL.standardizedFileURL == revealParent.standardizedFileURL,
            "at=\(activePane?.currentURL.lastPathComponent ?? "nil") expected=\(revealParent.lastPathComponent)")
        try? FileManager.default.removeItem(at: revealParent)
        // Opening a viewable file (Pathem as the default app for a PDF/image) presents the built-in
        // viewer, not just a reveal.
        let openPDF = openDir.appendingPathComponent("opened.pdf")
        try? FileManager.default.createDirectory(at: openDir, withIntermediateDirectories: true)
        let openDoc = PDFDocument()
        openDoc.insert(PDFPage(), at: 0)
        openDoc.write(to: openPDF)
        openExternalFolder(openPDF)
        check("open-viewable-presents-viewer", activePane?.isShowingViewer == true,
            "showing=\(activePane?.isShowingViewer == true)")
        activePane?.dismissViewer()
        try? FileManager.default.removeItem(at: openDir)
        // Regression (LAST -- it swaps the active pane's view mode): a view-mode swap builds a fresh
        // content view, and its rows must stay draggable. directoryURL -- which each list row
        // resolves its file URL against in pasteboardWriterForRow -- is set synchronously by reload,
        // not only in the async listing completion, so a freshly swapped list drags at once. This is
        // the "went back into the app and could no longer drag, only select" bug: rows showed but
        // directoryURL was nil, so nothing was draggable.
        activePane?.setViewMode(.list)  // normalize to list (no-op if already)
        let dragOnList = activePane?.debugListRowsDraggable() == true
        activePane?.setViewMode(.icon)  // swap away to a fresh icon view
        activePane?.setViewMode(.list)  // swap back to a fresh list view
        let dragAfterSwap = activePane?.debugListRowsDraggable() == true
        check("list-rows-draggable", dragOnList && dragAfterSwap, "onList=\(dragOnList) afterSwap=\(dragAfterSwap)")
        // Tab dragging (LAST -- it opens/moves tabs): the drag gestures are just thin wrappers over
        // moveTab / takeTab / adoptTab, so exercise those. A side must never be left empty: the last
        // tab is never taken, which is what stops a tear-off or cross-pane move from emptying a side.
        let leftBefore = leftTabs.tabCount
        let rightBefore = rightTabs.tabCount
        leftTabs.openTab(at: URL(fileURLWithPath: "/tmp"))
        leftTabs.openTab(at: URL(fileURLWithPath: "/usr"))
        let opened = leftTabs.tabCount == leftBefore + 2
        let lastFolder = leftTabs.tabFolders.last ?? ""
        leftTabs.moveTab(from: leftTabs.tabCount - 1, to: 0)  // drag it to the front
        let reordered = leftTabs.tabFolders.first == lastFolder
        var movedAcross = false
        if let url = leftTabs.takeTab(at: 0) {  // drag it onto the other side's bar
            rightTabs.adoptTab(url: url, at: rightTabs.tabCount)
            movedAcross = rightTabs.tabCount == rightBefore + 1 && leftTabs.tabCount == leftBefore + 1
        }
        // A lone tab is never taken away, so a side can't be emptied by a drag.
        let solo = TabbedPaneController(start: URL(fileURLWithPath: "/tmp"))
        solo.openInitialTab()
        let keptLast = solo.takeTab(at: 0) != nil && solo.tabCount == 1
        check(
            "tab-drag-reorder-move-teardown", opened && reordered && movedAcross && keptLast,
            "opened=\(opened) reordered=\(reordered) movedAcross=\(movedAcross) keptLast=\(keptLast)")
        // Open With ranks apps by how well they fit the type (not LaunchServices' arbitrary order):
        // an exact-type editor outranks a real-supertype claim, which outranks a catch-all "opens
        // anything" app (the Illustrator-for-.txt case). Guards OpenWithRanker.score.
        let exactFit = OpenWithRanker.score([.init(types: [.plainText], extensions: [], editor: true)], fileType: .plainText, ext: "txt")
        let superFit = OpenWithRanker.score([.init(types: [.text], extensions: [], editor: false)], fileType: .plainText, ext: "txt")
        let catchFit = OpenWithRanker.score([.init(types: [.data], extensions: [], editor: false)], fileType: .plainText, ext: "txt")
        check(
            "open-with-ranks-by-fit", exactFit > superFit && superFit > catchFit,
            "exact=\(exactFit) super=\(superFit) catch=\(catchFit)")
        // The transient-status channel (our toast): flashing a message puts it in the status line.
        // Copy Path/Name/Checksum and the "transfer already running" guard use this instead of a
        // silent success or a bare beep.
        leftTabs.activePane?.flashStatus("smoke-flash-probe")
        check(
            "status-flash-channel", leftTabs.activePane?.debugStatusText() == "smoke-flash-probe",
            "status=\(leftTabs.activePane?.debugStatusText() ?? "nil")")
        return (ok, lines)
    }
}

/// Cross-thread result box for the smoke promise check (the fulfillment completion runs on a
/// background OperationQueue). Reference type so the closures mutate one shared instance.
private final class SmokePromiseResult: @unchecked Sendable {
    var name = ""
    var error: Error?
}
