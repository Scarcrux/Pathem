#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func checkOperationStability(
        root: URL, check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool
    ) {
        let fm = FileManager.default
        guard let window = view.window, let pane = leftTabs.activePane else {
            check("stability-window", false)
            return
        }
        func report(_ name: String, _ ok: Bool) { check("stability-" + name, ok) }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        func answer(_ tag: Int) {
            cursorConfirm.debugPopover?.contentViewController.map {
                buttons($0.view).first { $0.tag == tag }?.performClick(nil)
            }
        }
        func presented() -> Bool { settle { cursorConfirm.debugPopover?.isShown == true } }
        func cancelled() -> Bool {
            settle { cursorConfirm.debugPopover == nil && !fileConfirmationPending }
        }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        let saved = prefs
        defer {
            prefs = saved
            debugTrashHandler = nil
            pane.debugWillApplyListing = nil
        }
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.makeKeyAndOrderFront(nil)
        setActiveSide(leftTabs, pane: pane)
        do {
            let source = try folder("source")
            let destination = try folder("destination")
            let urls = ["a.txt", "b.txt"].map { source.appendingPathComponent($0) }
            for url in urls {
                try Data("source".utf8).write(to: url)
                try Data("destination".utf8).write(
                    to: destination.appendingPathComponent(url.lastPathComponent))
            }
            pane.debugClickViewSwitcher(.list)
            let before = pane.debugListingCompletions
            pane.navigate(to: source)
            report(
                "source-listing",
                settle { pane.debugListingCompletions > before && pane.debugEntryCount == 2 })
            pane.debugSelectNames(["a.txt", "b.txt"])
            prefs.conflictDefault = .ask
            filePasteboard.clearContents()
            filePasteboard.writeObjects(urls as [NSURL])
            var completions = 0
            var copied = 0
            func request() {
                resolveThenTransfer(urls: urls, into: destination, move: false, conflictCount: 2) {
                    completions += 1
                    copied += $0.performed.count
                }
            }
            request()
            report("conflict-presented", presented())
            report(
                "conflict-batch-label",
                cursorConfirm.debugPopover?.contentViewController.map {
                    buttons($0.view).contains { $0.title == L("bvc.replaceAll", "Replace All") }
                } == true)
            let first = cursorConfirm.debugPopover
            report("pending-disables-file-paste", !canPasteFiles(into: destination))
            var refusedUnrelatedPrompt = false
            Task { @MainActor in
                refusedUnrelatedPrompt =
                    await cursorConfirm.ask(
                        message: "Unrelated pending-request control",
                        buttons: ["Continue", "Cancel"], over: view) == nil
            }
            pump()
            report(
                "confirmer-does-not-replace-pending",
                refusedUnrelatedPrompt && cursorConfirm.debugPopover === first)
            request()
            pump()
            report(
                "conflict-duplicate-keeps-prompt",
                cursorConfirm.debugPopover === first && completions == 0)
            answer(3)
            report(
                "conflict-cancel-no-operation", cancelled() && completions == 0 && !transferInFlight
            )
            report("cancel-reenables-file-paste", canPasteFiles(into: destination))
            request()
            report("conflict-retry-presented", presented())
            answer(1)  // Keep Both applies to the two-file batch, never owner data.
            report(
                "conflict-batch-once",
                settle { completions == 1 && copied == 2 && !transferInFlight })
            report(
                "conflict-batch-files",
                urls.allSatisfy {
                    fm.fileExists(
                        atPath: destination.appendingPathComponent(
                            $0.deletingPathExtension().lastPathComponent + " copy.txt"
                        ).path)
                })

            prefs.confirmBeforeDelete = true
            var trashBatches: [[URL]] = []
            debugTrashHandler = { trashBatches.append($0) }
            pane.debugSelectNames(["a.txt", "b.txt"])
            trashSelection()
            report("trash-presented", presented())
            report(
                "trash-batch-label",
                cursorConfirm.debugPopover?.contentViewController.map {
                    buttons($0.view).contains {
                        $0.title == L("bvc.moveAllToTrash", "Move All to Trash")
                    }
                } == true)
            let trashPrompt = cursorConfirm.debugPopover
            trashSelection()
            pump()
            report(
                "trash-duplicate-keeps-prompt",
                cursorConfirm.debugPopover === trashPrompt && trashBatches.isEmpty)
            // A different file action must not steal/cancel the pending destructive decision.
            request()
            pump()
            report("cross-action-keeps-prompt", cursorConfirm.debugPopover === trashPrompt)
            // Cancel whichever prompt is current; baseline may have improperly replaced Trash.
            if cursorConfirm.debugPopover === trashPrompt { answer(1) } else { answer(3) }
            report("trash-cancel-no-operation", cancelled() && trashBatches.isEmpty)
            trashSelection()
            report("trash-retry-presented", presented())
            answer(0)
            report(
                "trash-whole-selection-once",
                settle { trashBatches.count == 1 } && Set(trashBatches.first ?? []) == Set(urls))
            debugTrashHandler = nil

            // Passive metadata resort must keep an actual nonzero clip origin, not follow selection.
            let listing = try folder("listing")
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<160 {
                let url = listing.appendingPathComponent(String(format: "file-%03d.txt", index))
                try Data("fixture".utf8).write(to: url)
                try fm.setAttributes(
                    [.modificationDate: base.addingTimeInterval(Double(index))],
                    ofItemAtPath: url.path)
            }
            let beforeListing = pane.debugListingCompletions
            pane.navigate(to: listing)
            report(
                "viewport-listing",
                settle {
                    pane.debugListingCompletions > beforeListing && pane.debugEntryCount == 160
                })
            let sortReceipt = pane.debugListingCompletions
            pane.debugFireSort(.date, ascending: true)
            report(
                "viewport-sort-delivered",
                settle {
                    pane.debugListingCompletions > sortReceipt
                        && pane.debugEntryPosition("file-090.txt") == 90
                })
            pane.select(name: "file-090.txt")
            pump()
            guard let clip = pane.keyView.enclosingScrollView?.contentView else {
                report("viewport-clip", false)
                return
            }
            let offset = clip.bounds.origin
            report("viewport-input-delivered", offset.y > 1 && pane.debugRowVisible("file-090.txt"))
            let receipt = pane.debugListingCompletions
            let edited = listing.appendingPathComponent("file-090.txt")
            try fm.setAttributes(
                [.modificationDate: base.addingTimeInterval(10_000)], ofItemAtPath: edited.path)
            pane.reload()
            report(
                "resort-delivered",
                settle {
                    pane.debugListingCompletions > receipt
                        && pane.debugEntryPosition("file-090.txt") == 159
                })
            report(
                "passive-resort-keeps-viewport",
                abs(clip.bounds.origin.y - offset.y) < 1
                    && pane.currentURL.standardizedFileURL.path == listing.standardizedFileURL.path)
            print(
                "STABILITYGEOMETRY passive before=\(offset) after=\(clip.bounds.origin) pathsEqual=\(pane.currentURL.standardizedFileURL.path == listing.standardizedFileURL.path) urlsEqual=\(pane.currentURL == listing)"
            )
            report(
                "passive-resort-keeps-selection",
                pane.selectedEntries.map(\.name) == ["file-090.txt"])
            pane.reveal(edited)
            report(
                "explicit-reveal-still-scrolls",
                settle {
                    pane.debugRowVisible("file-090.txt")
                        && pane.selectedEntries.map(\.name) == ["file-090.txt"]
                })
            pane.debugFireSort(.date, ascending: false)
            report(
                "explicit-sort-still-reveals",
                settle {
                    pane.debugEntryPosition("file-090.txt") == 0
                        && pane.debugRowVisible("file-090.txt")
                })

            // Deliver an edit precisely after enumeration, before its listing would recycle cells.
            var beganEditing = false
            let beforeEdit = pane.debugListingCompletions
            pane.debugWillApplyListing = { beganEditing = pane.beginInlineRename() }
            pane.reload()
            report("late-inline-edit-delivered", settle { beganEditing })
            report(
                "late-inline-edit-not-recycled",
                pane.debugInlineEditing && pane.debugListingCompletions == beforeEdit)
            window.makeFirstResponder(pane.keyView)
            report(
                "deferred-listing-catches-up",
                settle { !pane.debugInlineEditing && pane.debugListingCompletions > beforeEdit })

            let namesReceipt = pane.debugListingCompletions
            pane.debugFireSort(.name, ascending: true)
            report(
                "rename-sort-delivered",
                settle {
                    pane.debugListingCompletions > namesReceipt
                        && pane.debugEntryPosition("file-000.txt") == 0
                })
            var lastRename: (from: String, to: String)?
            for mode in ViewFormat.ViewMode.allCases {
                let count = pane.debugListingCompletions
                pane.debugClickViewSwitcher(mode)
                pane.reload()
                report(
                    "refresh-view-delivered-\(mode.rawValue)",
                    settle {
                        pane.debugListingCompletions > count && pane.debugEntryCount == 160
                            && pane.viewMode == mode
                    })
                guard let last = pane.entries.last?.name else {
                    report("refresh-anchor-\(mode.rawValue)", false)
                    continue
                }
                pane.select(name: last)
                pump()
                guard let modeClip = pane.keyView.enclosingScrollView?.contentView else {
                    report("refresh-clip-\(mode.rawValue)", false)
                    continue
                }
                let point = modeClip.bounds.origin
                report("refresh-nonzero-\(mode.rawValue)", point.x > 1 || point.y > 1)
                let receipt = pane.debugListingCompletions
                pane.reload()
                report(
                    "refresh-response-\(mode.rawValue)",
                    settle { pane.debugListingCompletions > receipt })
                report(
                    "refresh-retains-\(mode.rawValue)",
                    abs(modeClip.bounds.origin.x - point.x) < 1
                        && abs(modeClip.bounds.origin.y - point.y) < 1
                        && pane.selectedEntries.map(\.name) == [last])
                print(
                    "STABILITYGEOMETRY refresh mode=\(mode.rawValue) before=\(point) after=\(modeClip.bounds.origin) selected=\(pane.selectedEntries.map(\.name)) expected=\(last)"
                )
                guard let entry = pane.entries.first(where: { $0.name == last }) else {
                    report("rename-entry-\(mode.rawValue)", false)
                    continue
                }
                let renamed = "000-\(mode.rawValue).txt"
                let renameReceipt = pane.debugListingCompletions
                commitLocalRename(entry, to: renamed, pane: pane)
                report(
                    "rename-delivered-\(mode.rawValue)",
                    settle {
                        pane.debugListingCompletions > renameReceipt
                            && (pane.debugEntryPosition(renamed) ?? Int.max) < 6
                            && pane.selectedEntries.map(\.name) == [renamed]
                    })
                report(
                    "rename-retains-viewport-\(mode.rawValue)",
                    abs(modeClip.bounds.origin.x - point.x) < 1
                        && abs(modeClip.bounds.origin.y - point.y) < 1)
                lastRename = (last, renamed)
            }
            if let lastRename, let undoClip = pane.keyView.enclosingScrollView?.contentView {
                let origin = undoClip.bounds.origin
                let beforeUndo = pane.debugListingCompletions
                actionHistory.undo()
                report(
                    "rename-undo-delivered",
                    settle {
                        pane.debugListingCompletions > beforeUndo
                            && pane.selectedEntries.map(\.name) == [lastRename.from]
                            && fm.fileExists(
                                atPath: listing.appendingPathComponent(lastRename.from).path)
                    })
                report("rename-undo-retains-viewport", abs(undoClip.bounds.origin.y - origin.y) < 1)
                let beforeRedo = pane.debugListingCompletions
                actionHistory.redo()
                report(
                    "rename-redo-delivered",
                    settle {
                        pane.debugListingCompletions > beforeRedo
                            && pane.selectedEntries.map(\.name) == [lastRename.to]
                            && fm.fileExists(
                                atPath: listing.appendingPathComponent(lastRename.to).path)
                    })
                report("rename-redo-retains-viewport", abs(undoClip.bounds.origin.y - origin.y) < 1)
            }

            // Actual list delegates, private pasteboard, and explicit modifier-event receipts.
            let content = FileListController()
            content.directoryURL = source
            content.setEntries(
                try BulkEnumerator().entries(of: source, includingHidden: false),
                preserveState: false)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.writeObjects([urls[0] as NSURL])
            let drag = TransferDraggingInfo(board, window: window)
            var menuCalls = 0
            var dropCalls = 0
            content.onDropOntoFile = { _, _ in menuCalls += 1 }
            content.onDropFiles = { _, _, _ in dropCalls += 1 }
            let row = content.entries.firstIndex { $0.name == "b.txt" } ?? -1
            let table = content.keyView as! NSTableView
            func withFlags(_ flags: NSEvent.ModifierFlags, _ action: () -> Void) -> Bool {
                let marker = Int.random(in: 1...Int.max)
                guard
                    let event = NSEvent.otherEvent(
                        with: .applicationDefined, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, subtype: 0,
                        data1: marker, data2: 0)
                else { return false }
                NSApp.postEvent(event, atStart: true)
                let received = NSApp.nextEvent(
                    matching: .applicationDefined, until: Date().addingTimeInterval(1),
                    inMode: .default, dequeue: true)
                guard received?.data1 == marker, NSApp.currentEvent?.modifierFlags == flags else {
                    return false
                }
                action()
                return true
            }
            var accepted = true
            let ordinary = withFlags([]) {
                accepted = content.tableView(table, acceptDrop: drag, row: row, dropOperation: .on)
            }
            report(
                "ordinary-same-folder-drop-noop",
                ordinary && !accepted && menuCalls == 0 && dropCalls == 0)
            let menusBeforeOption = menuCalls
            let option = withFlags(.option) {
                accepted = content.tableView(table, acceptDrop: drag, row: row, dropOperation: .on)
            }
            report(
                "option-file-drop-advanced-menu",
                option && accepted && menuCalls == menusBeforeOption + 1 && dropCalls == 0)
            report(
                "drop-fixtures-untouched",
                urls.allSatisfy { (try? String(contentsOf: $0, encoding: .utf8)) == "source" })

            board.clearContents()
            board.writeObjects([destination.appendingPathComponent("a.txt") as NSURL])
            let incomingMenus = menuCalls
            let incomingDrops = dropCalls
            let incoming = withFlags([]) {
                accepted = content.tableView(table, acceptDrop: drag, row: row, dropOperation: .on)
            }
            report(
                "ordinary-incoming-drop-routes-folder",
                incoming && accepted && menuCalls == incomingMenus && dropCalls == incomingDrops + 1
            )

            let downloads = try folder("downloads")
            for name in ["a.pdf", "b.pdf", ".hidden.pdf", "unfinished.pdf.part"] {
                try Data("fixture".utf8).write(to: downloads.appendingPathComponent(name))
            }
            report("downloads-startup-isolated", !downloadSuggestions.debugIsWatching)
            let firstDownloads = downloadSuggestions  // real bar mounted in this private test window
            let secondDownloads = DownloadSuggestionsController()
            let existingDownloads = DownloadSuggestionsController()
            defer {
                firstDownloads.debugReset()
                secondDownloads.debugReset()
                existingDownloads.debugReset()
            }
            existingDownloads.debugRunCheck(
                folder: downloads,
                seedKnown: ["a.pdf", "b.pdf", ".hidden.pdf", "unfinished.pdf.part"],
                feedbackURL: nil)
            report(
                "downloads-existing-no-prompt",
                existingDownloads.debugCurrentName == nil
                    && existingDownloads.debugQueuedNames.isEmpty)
            firstDownloads.debugRunCheck(folder: downloads, seedKnown: [], feedbackURL: nil)
            report(
                "downloads-new-arrivals-delivered",
                firstDownloads.debugCurrentName == "a.pdf"
                    && firstDownloads.debugQueuedNames == ["b.pdf"])
            window.setContentSize(NSSize(width: 720, height: 600))
            pump()
            view.layoutSubtreeIfNeeded()
            firstDownloads.view.layoutSubtreeIfNeeded()
            report(
                "downloads-chip-mounted",
                firstDownloads.view.window === window && !firstDownloads.view.isHidden)
            let chipRect = firstDownloads.view.convert(firstDownloads.view.bounds, to: view)
            report(
                "downloads-chip-contained-small-window",
                view.bounds.contains(chipRect) && chipRect.width > 100)
            report(
                "downloads-buttons-not-clipped",
                buttons(firstDownloads.view).allSatisfy {
                    $0.bounds.width >= $0.fittingSize.width - 1 && $0.bounds.height > 10
                })
            secondDownloads.debugRunCheck(folder: downloads, seedKnown: [], feedbackURL: nil)
            report(
                "downloads-one-window-claims-path",
                secondDownloads.debugCurrentName == nil && secondDownloads.debugQueuedNames.isEmpty)
            let original = downloads.appendingPathComponent("a.pdf")
            let held = root.appendingPathComponent("held.pdf")
            try fm.moveItem(at: original, to: held)
            firstDownloads.debugRefresh()
            try fm.moveItem(at: held, to: original)
            firstDownloads.debugRefresh()
            report(
                "downloads-reappear-no-duplicate",
                firstDownloads.debugCurrentName == "a.pdf"
                    && firstDownloads.debugQueuedNames == ["b.pdf"])
            firstDownloads.debugDismissAllButton.performClick(nil)
            report(
                "downloads-dismiss-all-clears-batch",
                firstDownloads.debugCurrentName == nil && firstDownloads.debugQueuedNames.isEmpty)
            firstDownloads.debugRefresh()
            report("downloads-dismiss-all-no-replay", firstDownloads.debugCurrentName == nil)
            try Data("fixture".utf8).write(to: downloads.appendingPathComponent("c.pdf"))
            firstDownloads.debugRefresh()
            report(
                "downloads-future-arrival-not-approved", firstDownloads.debugCurrentName == "c.pdf")
            firstDownloads.stop()
            report(
                "downloads-stop-clears-ui",
                firstDownloads.debugCurrentName == nil && firstDownloads.debugQueuedNames.isEmpty
                    && !firstDownloads.debugIsWatching)
            firstDownloads.debugRefresh()
            report("downloads-stopped-response-ignored", firstDownloads.debugCurrentName == nil)
            secondDownloads.stop()
            secondDownloads.debugRunCheck(folder: downloads, seedKnown: [], feedbackURL: nil)
            report(
                "downloads-stop-releases-other-window", secondDownloads.debugCurrentName == "a.pdf")
            report("downloads-default-opt-in", !Preferences.default.downloadSuggestionsEnabled)
            secondDownloads.stop()
            secondDownloads.start(feedbackURL: nil)  // folderOverride is the disposable fixture root
            report(
                "downloads-private-watcher-started",
                secondDownloads.debugIsWatching && secondDownloads.debugCurrentName == nil)
            try Data("fixture".utf8).write(to: downloads.appendingPathComponent("event.pdf"))
            report(
                "downloads-real-fsevent-delivered",
                settle { secondDownloads.debugCurrentName == "event.pdf" })
            secondDownloads.stop()
            try Data("fixture".utf8).write(to: downloads.appendingPathComponent("late.pdf"))
            pump()
            report(
                "downloads-stopped-watcher-no-reopen",
                !secondDownloads.debugIsWatching && secondDownloads.debugCurrentName == nil)
            report(
                "downloads-owner-folder-not-watched-in-tests", !downloadSuggestions.debugIsWatching)
            if settingsPanel != nil { closeSettingsPanel() }
            showPreferences()
            let optIn = buttons(view).first {
                $0.title
                    == L("prefs.downloadSuggestions", "Offer filing suggestions for new downloads")
            }
            report(
                "downloads-opt-in-control-mounted", optIn?.window === window && optIn?.state == .off
            )
            optIn?.performClick(nil)
            report(
                "downloads-opt-in-control-applies",
                prefs.downloadSuggestionsEnabled && optIn?.state == .on
                    && !downloadSuggestions.debugIsWatching)
            optIn?.performClick(nil)
            report(
                "downloads-opt-out-control-applies",
                !prefs.downloadSuggestionsEnabled && optIn?.state == .off
                    && !downloadSuggestions.debugIsWatching)
            closeSettingsPanel()
        } catch {
            report("fixture-error", false)
            print("STABILITYERROR: \(error)")
        }
    }
}
#endif
