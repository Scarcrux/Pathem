#if DEBUG
import AppKit
import PathemEngine

/// A real private pasteboard delivered through the production destination delegates.
@MainActor
final class TransferDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@MainActor
extension BrowserViewController {
    func runSidebarTransferUIAutomation() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-sidebar-transfer-\(UUID())")
        let board = NSPasteboard.withUniqueName()
        debugFilePasteboard = board
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) {
            checks.append((name, ok))
            print("SIDEBARTRANSFER: \(ok ? "PASS" : "FAIL") \(name)")
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(5)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        func finish() -> Never {
            board.releaseGlobally()
            try? fm.removeItem(at: root)
            let passed = checks.filter(\.1).count
            print("RESULT: \(passed == checks.count ? "PASS" : "FAIL") (\(passed)/\(checks.count))")
            exit(passed == checks.count ? 0 : 1)
        }
        guard let window = view.window, let pane = leftTabs.activePane else {
            check("window-and-pane", false)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_OPERATION_STABILITY_SAMPLE"] == "1" {
            checkOperationStability(root: root, check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_DIALOG_LAYOUT_SAMPLE"] == "1" {
            checkDialogLayout(check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_WIDTH_SAMPLE"] == "1" {
            checkSidebarWidthKept(check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_TERMINAL_DRAWER_SAMPLE"] == "1" {
            checkTerminalDrawer(check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_FIND_IN_FILES_SAMPLE"] == "1" {
            checkFindInFiles(check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_SEMANTIC_SEARCH_SAMPLE"] == "1" {
            checkSemanticSearch(root: root, check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_VIEW_OPTIONS_SAMPLE"] == "1" {
            checkViewOptions(root: root, check: check, settle: settle)
            finish()
        }
        if ProcessInfo.processInfo.environment["PATHEM_SORT_GROUP_SAMPLE"] == "1" {
            checkSortGroupDelivery(
                root: root.appendingPathComponent("sort-group"), check: check, settle: settle)
            finish()
        }
        // nextEvent establishes NSApp.currentEvent; sendEvent alone does not do so
        // before NSApplication.run. Verify receipt before exercising the delegates.
        func withCommand(_ command: Bool, action: () -> Void) -> Bool {
            let marker = Int.random(in: 1...Int.max)
            guard
                let event = NSEvent.otherEvent(
                    with: .applicationDefined, location: .zero,
                    modifierFlags: command ? .command : [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    subtype: 0, data1: marker, data2: 0)
            else { return false }
            NSApp.postEvent(event, atStart: true)
            let received = NSApp.nextEvent(
                matching: .applicationDefined, until: Date().addingTimeInterval(1),
                inMode: .default,
                dequeue: true)
            print(
                "DRAGRECEIPT: payload=\(received?.data1 == marker) currentPayload=\(NSApp.currentEvent?.data1 == marker) command=\(command)"
            )
            guard received?.data1 == marker, NSApp.currentEvent?.data1 == marker,
                NSApp.currentEvent?.modifierFlags.contains(.command) == command
            else { return false }
            action()
            return true
        }
        let source = root.appendingPathComponent("source")
        let favorite = root.appendingPathComponent("favorite")
        let cloud = root.appendingPathComponent("cloud")
        let child = cloud.appendingPathComponent("child")
        let file = source.appendingPathComponent("sample.txt")
        do {
            for folder in [source, favorite, child] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try "transfer bytes".write(to: file, atomically: true, encoding: .utf8)
        } catch {
            check("fixture-created", false)
            finish()
        }
        sidebar.demoMode = true
        sidebar.demoCloud = [("Fixture Cloud", cloud)]
        sidebar.model = Sidebar(groups: [
            .init(
                title: "Transfer fixtures",
                items: [
                    .init(name: "Favorite", icon: "folder", path: favorite.path),
                    .init(name: "Source", icon: "folder", path: source.path),
                    .init(
                        name: "Missing", icon: "folder",
                        path: root.appendingPathComponent("missing").path),
                ])
        ])
        window.makeKeyAndOrderFront(nil)
        pane.navigate(to: source)
        check("listing-delivered", settle { pane.debugHasEntry("sample.txt") })
        pane.debugSelectNames(["sample.txt"])
        cut(nil)
        check(
            "cut-delivered",
            cutPaths.contains(file.path) && board.data(forType: Self.cutPasteboardType) != nil)
        func pasteItem(_ folder: URL) -> NSMenuItem? {
            sidebar.debugMenu(for: folder)?.items.first {
                $0.action == Selector(("pasteIntoTarget:"))
            }
        }
        func dispatch(_ item: NSMenuItem?) -> Bool {
            guard let item, item.isEnabled, let action = item.action,
                let target = item.target as? NSObject
            else { return false }
            return NSApp.sendAction(action, to: target, from: item)
        }
        let moveItem = pasteItem(favorite)
        check("favorite-paste-enabled", moveItem?.isEnabled == true)
        check("menu-paste-dispatched", dispatch(moveItem))
        let moved = favorite.appendingPathComponent(file.lastPathComponent)
        check(
            "cut-goes-to-clicked-folder-not-pane",
            settle {
                !transferInFlight && fm.fileExists(atPath: moved.path)
                    && !fm.fileExists(atPath: file.path)
            } && pane.currentURL.standardizedFileURL == source.standardizedFileURL)
        check("cut-marker-and-dimming-cleared", board.types?.isEmpty != false && cutPaths.isEmpty)
        undo(nil)
        check(
            "sidebar-move-undo-restores-source",
            settle {
                fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: moved.path)
            })
        check("source-reloaded", settle { pane.debugHasEntry(file.lastPathComponent) })
        pane.debugSelectNames([file.lastPathComponent])
        copy(nil)
        check("system-location-paste-dispatched", dispatch(pasteItem(cloud)))
        check(
            "copy-retains-source-and-bytes",
            settle {
                !transferInFlight
                    && (try? String(
                        contentsOf: cloud.appendingPathComponent(file.lastPathComponent),
                        encoding: .utf8)) == "transfer bytes"
            } && fm.fileExists(atPath: file.path))
        transferInFlight = true
        check("busy-transfer-disables-paste", pasteItem(favorite)?.isEnabled == false)
        transferInFlight = false
        check(
            "missing-folder-disables-paste",
            pasteItem(root.appendingPathComponent("missing"))?.isEnabled == false)
        board.clearContents()
        board.setString("not a file", forType: .string)
        check("text-clipboard-disables-file-paste", pasteItem(favorite)?.isEnabled == false)
        board.clearContents()
        check("empty-clipboard-disables-paste", pasteItem(favorite)?.isEnabled == false)

        // Keyboard Paste must use the sidebar selection even with a different active pane.
        board.writeObjects([file as NSURL])
        sidebar.highlightFolder(favorite)
        check("sidebar-keyboard-focus", window.makeFirstResponder(sidebar.debugOutline))
        check(
            "keyboard-paste-dispatched",
            sidebar.debugOutline.tryToPerform(#selector(NSText.paste(_:)), with: nil))
        check(
            "keyboard-paste-targets-selected-folder",
            settle { !transferInFlight && fm.fileExists(atPath: moved.path) })

        // Text fields remain their own Paste target; file Paste is not intercepted.
        let renameItem = sidebar.debugMenu(for: favorite)?.items.first {
            $0.action == Selector(("renameTarget"))
        }
        check("sidebar-inline-rename-dispatched", dispatch(renameItem))
        check(
            "text-field-editor-retains-paste",
            window.firstResponder is NSTextView && !sidebar.hasKeyboardFocus)
        window.makeFirstResponder(pane.keyView)

        let drag = TransferDraggingInfo(board, window: window)
        let segment = BreadcrumbSegment(folder: favorite)
        let up = NavDragButton()
        up.dropDestination = { favorite }
        let originalDrop = sidebar.onDropFilesIntoFolder
        var delivered: [(String, Bool, URL)] = []
        func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.resolvingSymlinksInPath().standardizedFileURL.path
                == rhs.resolvingSymlinksInPath().standardizedFileURL.path
        }
        func isSource(_ urls: [URL]) -> Bool {
            urls.count == 1 && sameLocation(urls[0], file)
        }
        sidebar.onDropFilesIntoFolder = { urls, folder, move in
            if isSource(urls) { delivered.append(("sidebar", move, folder)) }
        }
        segment.onDropURLs = { urls, move in
            if isSource(urls) { delivered.append(("breadcrumb", move, favorite)) }
        }
        up.onDropURLs = { urls, move, folder in
            if isSource(urls) { delivered.append(("up", move, folder)) }
        }
        for moveDefault in [true, false] {
            prefs.dragMovesByDefault = moveDefault
            applyPreferences()
            segment.dragMovesByDefault = moveDefault
            up.dragMovesByDefault = moveDefault
            check(
                "preference-delivered-\(moveDefault)",
                sidebar.dragMovesByDefault == moveDefault
                    && pane.debugDragPreferences.allSatisfy { $0 == moveDefault })
            leftTabs.openTab(at: source)
            check(
                "new-tab-inherits-preference-\(moveDefault)",
                leftTabs.activePane?.debugDragPreferences.allSatisfy { $0 == moveDefault } == true)
            leftTabs.closeActiveTab()
            for command in [false, true] {
                let expected: NSDragOperation = moveDefault != command ? .move : .copy
                let masks: [NSDragOperation] = [[.copy, .move], .copy, []]
                for mask in masks {
                    drag.draggingSourceOperationMask = mask
                    let wanted: NSDragOperation =
                        mask.isEmpty ? [] : (mask == .copy ? .copy : expected)
                    var valid = false
                    let eventDelivered = withCommand(command) {
                        delivered = []
                        let sidebarOp = sidebar.debugDrop(drag, into: favorite, accept: true)
                        let breadcrumbOp = segment.draggingUpdated(drag)
                        let breadcrumbAccepted = segment.performDragOperation(drag)
                        let upOp = up.draggingUpdated(drag)
                        let upAccepted = up.performDragOperation(drag)
                        valid =
                            sidebarOp == wanted && breadcrumbOp == wanted && upOp == wanted
                            && breadcrumbAccepted == !wanted.isEmpty
                            && upAccepted == !wanted.isEmpty
                            && delivered.count == (wanted.isEmpty ? 0 : 3)
                            && delivered.allSatisfy {
                                $0.1 == (wanted == .move) && sameLocation($0.2, favorite)
                            }
                        print(
                            "DRAGVERDICT: sidebar=\(sidebarOp.rawValue) breadcrumb=\(breadcrumbOp.rawValue) up=\(upOp.rawValue) expected=\(wanted.rawValue) callbacks=\(delivered.count)"
                        )
                    }
                    check(
                        "drag-policy-default=\(moveDefault)-cmd=\(command)-mask=\(mask.rawValue)",
                        eventDelivered && valid)
                }
            }
        }
        sidebar.onDropFilesIntoFolder = originalDrop
        // The sidebar's real callback must transfer, not just advertise move.
        prefs.dragMovesByDefault = true
        applyPreferences()
        drag.draggingSourceOperationMask = [.copy, .move]
        check(
            "expanded-folder-delivered",
            settle {
                sidebar.debugExpandFolder(cloud)
                return sidebar.debugMenu(for: child) != nil
            })
        var accepted = false
        let deliveredMove = withCommand(false) {
            accepted = sidebar.debugDrop(drag, into: child, accept: true) == .move
        }
        check("sidebar-drag-move-accepted", deliveredMove && accepted)
        check(
            "sidebar-drag-moves-real-file",
            settle {
                !transferInFlight && !fm.fileExists(atPath: file.path)
                    && fm.fileExists(
                        atPath: child.appendingPathComponent(file.lastPathComponent).path)
            })
        checkFileSafety(root: root.appendingPathComponent("safety"), check: check, settle: settle)
        checkOperationStability(
            root: root.appendingPathComponent("stability"), check: check, settle: settle)
        checkViewOptions(
            root: root.appendingPathComponent("view-options"), check: check, settle: settle)
        checkDialogLayout(check: check, settle: settle)
        checkFindInFiles(check: check, settle: settle)
        checkSemanticSearch(
            root: root.appendingPathComponent("semantic"), check: check, settle: settle)
        checkTerminalDrawer(check: check, settle: settle)
        checkSidebarWidthKept(check: check, settle: settle)
        checkSortGroupDelivery(
            root: root.appendingPathComponent("sort-group"), check: check, settle: settle)
        finish()
    }
}
#endif
