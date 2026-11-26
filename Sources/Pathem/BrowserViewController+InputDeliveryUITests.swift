#if DEBUG
import AppKit
import PathemEngine

@MainActor
private struct InputDeliveryChecks {
    var count = 0
    var failures = 0

    mutating func check(_ name: String, _ passed: Bool) {
        count += 1
        if !passed { failures += 1 }
        print("INPUT DELIVERY: \(passed ? "PASS" : "FAIL") \(name)")
    }

    mutating func run(_ body: (inout Self) async throws -> Void) async -> Never {
        do {
            try await body(&self)
        } catch {
            check("fixture: \(error.localizedDescription)", false)
        }
        print(
            "RESULT: \(failures == 0 && count > 0 ? "PASS" : "FAIL") (\(count - failures)/\(count))"
        )
        exit(failures == 0 && count > 0 ? 0 : 1)
    }

    static func settle(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }
}

@MainActor
extension BrowserViewController {
    func runLiveKeyInputUIAutomation(demo: DemoWorkspace.Layout, window: NSWindow) async -> Never {
        print(
            "INPUT DELIVERY: synthetic NSEvents through NSApp.postEvent and the AppKit event loop; no CGEvent-level input (Accessibility not available)."
        )
        var checks = InputDeliveryChecks()
        await checks.run { checks in
            let fixtures = demo.root.appendingPathComponent("Key input fixture", isDirectory: true)
            try FileManager.default.createDirectory(
                at: fixtures, withIntermediateDirectories: false)
            let names = ["anchor.txt", "robin.txt", "rocket.txt"]
            for name in names {
                try Data(name.utf8).write(to: fixtures.appendingPathComponent(name))
            }
            guard await InputDeliveryChecks.settle({ self.leftTabs.activePane != nil }) else {
                checks.check("demo tabs loaded", false)
                return
            }

            @MainActor func post(
                _ type: NSEvent.EventType, _ code: UInt16, _ chars: String,
                _ flags: NSEvent.ModifierFlags
            ) {
                guard
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: code)
                else {
                    checks.check("constructed event \(type) keyCode=\(code)", false)
                    return
                }
                NSApp.postEvent(event, atStart: false)
            }

            @MainActor func key(
                _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []
            ) {
                post(.keyDown, code, chars, flags)
                post(.keyUp, code, chars, flags)
            }

            @MainActor func control(_ down: Bool) {
                post(.flagsChanged, 59, "", down ? .control : [])
            }

            leftTabs.openTab(at: demo.root)
            leftTabs.openTab(at: fixtures)
            guard let origin = leftTabs.activePane else {
                checks.check("fixture tab opened", false)
                return
            }
            setActiveSide(leftTabs, pane: origin)
            origin.debugClickViewSwitcher(.list)
            origin.focusList()
            let order = allTabEntries().map(\.id)
            guard order.count >= 3, order.first == ObjectIdentifier(origin) else {
                checks.check("at least three MRU tabs with focused origin", false)
                return
            }

            // Observe delivery without altering or consuming any of the posted events.
            var modifierTransitions: [Bool] = []
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                if event.keyCode == 59 && event.windowNumber == window.windowNumber {
                    modifierTransitions.append(event.modifierFlags.contains(.control))
                }
                return event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            control(true)
            key(48, "\t", .control)
            checks.check(
                "Ctrl-Tab selects previous tab and shows overlay when held",
                await InputDeliveryChecks.settle {
                    self.tabSwitcher.selection?.chosen == order[1]
                        && self.tabSwitcher.debugPanel?.isVisible == true
                })
            key(48, "\t", .control)
            checks.check(
                "second Tab advances before Ctrl release",
                await InputDeliveryChecks.settle {
                    self.tabSwitcher.selection?.chosen == order[2] && self.activePane === origin
                })
            control(false)
            checks.check(
                "Ctrl release commits the second most-recent alternative",
                await InputDeliveryChecks.settle {
                    self.activePane.map(ObjectIdentifier.init) == order[2]
                        && !self.tabSwitcher.isOpen
                })
            tabSwitcher.cancel()

            activePane?.focusList()
            let reverseOrder = allTabEntries().map(\.id)
            control(true)
            key(48, "\u{19}", [.control, .shift])
            checks.check(
                "Ctrl-Shift-Tab cycles backward",
                await InputDeliveryChecks.settle {
                    self.tabSwitcher.selection?.chosen == reverseOrder.last
                })
            control(false)
            checks.check(
                "backward choice commits on release",
                await InputDeliveryChecks.settle {
                    self.activePane.map(ObjectIdentifier.init) == reverseOrder.last
                        && !self.tabSwitcher.isOpen
                })
            tabSwitcher.cancel()

            activePane?.focusList()
            let quickTarget = allTabEntries()[1].id
            let presentations = tabSwitcher.debugPresentationCount
            control(true)
            key(48, "\t", .control)
            control(false)
            try await Task.sleep(for: .milliseconds(220))
            checks.check(
                "quick tap commits with no overlay flash",
                activePane.map(ObjectIdentifier.init) == quickTarget && !tabSwitcher.isOpen
                    && tabSwitcher.debugPanel == nil
                    && tabSwitcher.debugPresentationCount == presentations)
            tabSwitcher.cancel()
            checks.check(
                "AppKit delivered all three Ctrl press and release pairs",
                modifierTransitions == [true, false, true, false, true, false])

            guard let index = leftTabs.tabs.firstIndex(where: { $0 === origin }) else {
                checks.check("original list tab available", false)
                return
            }
            leftTabs.selectTab(index)
            setActiveSide(leftTabs, pane: origin)
            origin.focusList()
            prefs.findAsYouType = true
            vimMode = false
            let ready = await InputDeliveryChecks.settle {
                Set(origin.entries.map(\.name)) == Set(names)
            }
            checks.check(
                "focused list loaded all search fixtures",
                ready && window.firstResponder === origin.keyView)
            guard ready else { return }
            origin.selectNames(["anchor.txt"])
            let matches = origin.entries.map(\.name).filter { $0.hasPrefix("ro") }
            let ahead = origin.typeAhead
            key(15, "r")
            key(31, "o")
            checks.check(
                "ro opens the focused Find field and selects first match",
                await InputDeliveryChecks.settle {
                    ahead.isOpen && ahead.text == "ro" && ahead.effectiveMode == .find
                        && ahead.bar.field.currentEditor() === window.firstResponder
                        && origin.selectedEntries.map(\.name) == Array(matches.prefix(1))
                })
            key(125, "\u{F701}")
            checks.check(
                "Down selects the second match",
                await InputDeliveryChecks.settle {
                    origin.selectedEntries.map(\.name) == Array(matches.dropFirst())
                })
            key(126, "\u{F700}")
            checks.check(
                "Up returns to the first match",
                await InputDeliveryChecks.settle {
                    origin.selectedEntries.map(\.name) == Array(matches.prefix(1))
                })
            key(48, "\t")
            checks.check(
                "Tab switches to Filter and hides the nonmatching row",
                await InputDeliveryChecks.settle {
                    ahead.effectiveMode == .filter
                        && Set(origin.entries.map(\.name)) == Set(matches)
                })
            key(48, "\t")
            checks.check(
                "Tab switches back to Find",
                await InputDeliveryChecks.settle {
                    ahead.effectiveMode == .find && origin.entries.count == names.count
                })
            key(53, "\u{1B}")
            checks.check(
                "Escape restores the list focus, selection, and filter",
                await InputDeliveryChecks.settle {
                    !ahead.isOpen && window.firstResponder === origin.keyView
                        && origin.selectedEntries.map(\.name) == ["anchor.txt"]
                        && origin.currentFilterText.isEmpty
                })
            key(44, "/")
            checks.check(
                "slash enters Go",
                await InputDeliveryChecks.settle {
                    ahead.isOpen && ahead.effectiveMode == .go && ahead.text == "/"
                })
            key(53, "\u{1B}")
            checks.check(
                "Escape leaves Go and restores selection",
                await InputDeliveryChecks.settle {
                    !ahead.isOpen && origin.selectedEntries.map(\.name) == ["anchor.txt"]
                })

            keymap = keymap.merging(userBindings: ["x": "view.toggleHidden"])
            let hidden = origin.debugHiddenShown
            key(7, "x")
            checks.check(
                "bound printable key executes its command without opening Find",
                await InputDeliveryChecks.settle {
                    origin.debugHiddenShown != hidden && !ahead.isOpen
                })
        }
    }

    func runFinderTreeDropUIAutomation(demo: DemoWorkspace.Layout, window: NSWindow) async -> Never
    {
        print(
            "INPUT DELIVERY: Finder-shaped private pasteboard and synthesized NSDraggingInfo through the real NSOutlineView validateDrop/acceptDrop delegates; no Finder drag (Accessibility not available). Option is represented by a copy-only source mask."
        )
        var checks = InputDeliveryChecks()
        await checks.run { checks in
            let fm = FileManager.default
            let source = demo.root.appendingPathComponent("Drop source", isDirectory: true)
            let target = demo.root.appendingPathComponent("Drop target", isDirectory: true)
            for folder in [source, target] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let token = UUID().uuidString
            let files = ["\(token)-one.txt", "\(token)-two.txt"].map {
                source.appendingPathComponent($0)
            }
            let destinations = files.map { target.appendingPathComponent($0.lastPathComponent) }
            let payloads = [Data("first".utf8), Data("second".utf8)]
            for (url, data) in zip(files, payloads) { try data.write(to: url) }

            prefs.showFolderTree = true
            applyPreferences()
            folderTree.pin(target)
            folderTree.dragMovesByDefault = true
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let legacy = FileDrag.filenamesType
            let items = files.map { url in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
            let wroteItems = board.writeObjects(items)
            FileDrag.addLegacyFilenames(files, to: board)
            // AppKit can add compatibility flavors or a separate entry for the legacy
            // list. Verify both representations identify exactly the same two files.
            func canonicalPath(_ url: URL) -> String {
                url.resolvingSymlinksInPath().standardizedFileURL.path
            }
            let urlItems = board.pasteboardItems?.filter { $0.types.contains(.fileURL) } ?? []
            let readURLs = urlItems.compactMap { item -> String? in
                guard let value = item.string(forType: .fileURL),
                    let url = URL(string: value), url.isFileURL
                else { return nil }
                return canonicalPath(url)
            }
            let legacyPaths = (board.propertyList(forType: legacy) as? [String])?.map {
                canonicalPath(URL(fileURLWithPath: $0))
            }
            let expectedPaths = files.map(canonicalPath)
            checks.check(
                "private pasteboard carries two exact per-item URLs and the legacy path list",
                wroteItems && urlItems.count == files.count
                    && readURLs == expectedPaths && legacyPaths == expectedPaths)
            let info = TransferDraggingInfo(board, window: window)
            info.numberOfValidItemsForDrop = files.count
            info.draggingSourceOperationMask = []
            checks.check(
                "folder-tree delegate rejects an empty operation mask",
                folderTree.debugDrop(info, onto: target, accept: true).isEmpty
                    && destinations.allSatisfy { !fm.fileExists(atPath: $0.path) })

            func hasBytes(_ urls: [URL]) -> Bool {
                zip(urls, payloads).allSatisfy { (try? Data(contentsOf: $0.0)) == $0.1 }
            }

            for (label, mask, operation) in [
                ("move", NSDragOperation([.copy, .move]), NSDragOperation.move),
                ("Option copy", .copy, .copy),
            ] {
                let before = actionHistory.undoStack.last?.id
                info.draggingSourceOperationMask = mask
                let offered = folderTree.debugDrop(info, onto: target, accept: true)
                let completed = await InputDeliveryChecks.settle {
                    !self.transferInFlight && self.actionHistory.undoStack.last?.id != before
                        && hasBytes(destinations)
                }
                let sourceCorrect =
                    operation == .move
                    ? files.allSatisfy { !fm.fileExists(atPath: $0.path) }
                    : hasBytes(files)
                checks.check(
                    "\(label) accepted and both file payloads landed with correct source policy",
                    offered == operation && completed && sourceCorrect)
                guard completed else { return }
                undo(nil)
                checks.check(
                    "\(label) undo restores both originals and clears the destination",
                    hasBytes(files) && destinations.allSatisfy { !fm.fileExists(atPath: $0.path) })
            }
        }
    }
}
#endif
