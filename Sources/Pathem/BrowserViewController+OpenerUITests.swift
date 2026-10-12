#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func runOpenerUIAutomation() -> Never {
        var results: [Bool] = []
        func check(_ name: String, _ ok: Bool) {
            results.append(ok)
            print("OPENERUI: \(ok ? "PASS" : "FAIL") \(name)")
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(4)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        func descendants<T: NSView>(_ node: NSView, as type: T.Type) -> [T] {
            (node as? T).map { [$0] } ?? node.subviews.flatMap { descendants($0, as: type) }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-opener-\(UUID())")
        func finish() -> Never {
            try? fm.removeItem(at: root)
            let count = results.filter { $0 }.count
            print("RESULT: \(count == results.count ? "PASS" : "FAIL") (\(count)/\(results.count))")
            exit(count == results.count ? 0 : 1)
        }
        guard let window = view.window, let pane = activePane else {
            check("host", false)
            finish()
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("Fixture".utf8).write(to: root.appendingPathComponent("fixture.txt"))
        } catch {
            check("fixture", false)
            finish()
        }
        pane.navigate(to: root)
        guard settle({ pane.entries.contains { $0.name == "fixture.txt" } }) else {
            check("listing", false)
            finish()
        }
        pane.debugSelectNames(["fixture.txt"])
        check("file-selection-delivered", pane.selectedEntries.map(\.name) == ["fixture.txt"])
        let before = openerRules
        setDefaultOpener(nil)
        guard settle({ window.attachedSheet?.isVisible == true }),
            let sheet = window.attachedSheet, let content = sheet.contentView,
            let popup = descendants(content, as: NSPopUpButton.self).first(where: {
                $0.itemTitles.contains(L("bvc.chooseEllipsis", "Choose…"))
            })
        else {
            check("mounted-opener-popup", false)
            finish()
        }
        check("mounted-opener-popup", popup.window === sheet && popup.isEnabled)
        check("no-picker-before-choose-control", sheet.attachedSheet == nil)
        popup.selectItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))
        check("choose-action-delivered", popup.sendAction(popup.action, to: popup.target))
        let presented = settle {
            sheet.attachedSheet is NSOpenPanel && sheet.attachedSheet?.isVisible == true
        }
        check("choose-immediately-presents-native-picker", presented)
        if let panel = sheet.attachedSheet as? NSOpenPanel {
            panel.cancel(nil)
            check(
                "picker-cancel-keeps-opener-sheet",
                settle { sheet.attachedSheet == nil && window.attachedSheet === sheet })
        }
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        check(
            "cancel-does-not-save", settle { window.attachedSheet == nil } && openerRules == before)
        if ProcessInfo.processInfo.environment["PATHEM_OPENER_SAMPLE"] == "1" { finish() }

        func showOpener() -> (NSWindow, DefaultOpenerApplicationPopup, NSPopUpButton, NSButton)? {
            setDefaultOpener(nil)
            guard settle({ window.attachedSheet?.isVisible == true }),
                let sheet = window.attachedSheet, let content = sheet.contentView,
                let popup = descendants(content, as: DefaultOpenerApplicationPopup.self).first,
                let scope = descendants(content, as: NSPopUpButton.self).first(where: {
                    $0.itemTitles.contains(L("bvc.scopeThisFile", "This file"))
                }),
                let button = descendants(content, as: NSButton.self).first(where: {
                    $0.title == L("bvc.set", "Set")
                })
            else { return nil }
            return (sheet, popup, scope, button)
        }
        guard let (retrySheet, retryPopup, retryScope, retrySet) = showOpener(),
            let candidate = retryPopup.selectedItem?.representedObject as? URL
        else {
            check("candidate-control-delivered", false)
            finish()
        }
        check("candidate-enables-set", retrySet.isEnabled)
        retryScope.selectItem(at: 1)
        for cycle in 0..<2 {
            retryPopup.selectItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))
            check(
                "retry-action-\(cycle)",
                retryPopup.sendAction(retryPopup.action, to: retryPopup.target))
            guard settle({ retrySheet.attachedSheet?.isVisible == true }),
                let panel = retrySheet.attachedSheet as? NSOpenPanel
            else {
                check("retry-native-picker-\(cycle)", false)
                finish()
            }
            check(
                "picker-filters-\(cycle)",
                panel.allowedContentTypes == [.application]
                    && panel.canChooseFiles && !panel.canChooseDirectories
                    && !panel.allowsMultipleSelection)
            check(
                "picker-blocks-premature-set-\(cycle)", !retrySet.isEnabled && !retryPopup.isEnabled
            )
            // Duplicate target/action delivery must not create a queued second picker.
            _ = retryPopup.sendAction(retryPopup.action, to: retryPopup.target)
            check(
                "one-picker-\(cycle)",
                retrySheet.sheets.count == 1 && retrySheet.attachedSheet === panel)
            panel.cancel(nil)
            check(
                "retry-cancel-restores-choice-and-scope-\(cycle)",
                settle {
                    retrySheet.attachedSheet == nil && retryPopup.isEnabled && retrySet.isEnabled
                        && retryPopup.selectedItem?.representedObject as? URL == candidate
                        && retryScope.indexOfSelectedItem == 1
                })
        }
        window.endSheet(retrySheet, returnCode: .alertSecondButtonReturn)
        check(
            "retry-cancel-does-not-save",
            settle { window.attachedSheet == nil } && openerRules == before)

        let file = root.appendingPathComponent("fixture.txt")
        for scopeIndex in [0, 1, 3] {
            guard let (sheet, popup, scope, set) = showOpener(),
                let app = popup.selectedItem?.representedObject as? URL
            else {
                check("scope-controls-\(scopeIndex)", false)
                finish()
            }
            scope.selectItem(at: scopeIndex)
            check(
                "scope-input-\(scopeIndex)",
                scope.indexOfSelectedItem == scopeIndex && set.isEnabled)
            let diskBefore = loadConfig(OpenerRules.self, from: Self.openersURL)
            set.performClick(nil)
            check(
                "set-dismisses-\(scopeIndex)",
                settle { window.attachedSheet == nil && !sheet.isVisible })
            let disk = loadConfig(OpenerRules.self, from: Self.openersURL)
            switch scopeIndex {
            case 0:
                check(
                    "file-scope-real-save",
                    openerRules.byFile[file.path] == app.path && disk?.byFile[file.path] == app.path
                )
            case 1:
                check(
                    "folder-scope-real-save",
                    openerRules.byFolder[root.path] == app.path
                        && disk?.byFolder[root.path] == app.path)
            default:
                check(
                    "session-scope-memory-only",
                    sessionOpenersByType["txt"] == app.path && disk == diskBefore)
            }
        }

        let emptyAlert = NSAlert()
        emptyAlert.addButton(withTitle: L("bvc.set", "Set"))
        emptyAlert.addButton(withTitle: L("common.cancel", "Cancel"))
        let emptySet = emptyAlert.buttons[0]
        let emptyPopup = DefaultOpenerApplicationPopup(apps: [], setButton: emptySet)
        emptyAlert.accessoryView = emptyPopup
        emptyAlert.beginSheetModal(for: window)
        check(
            "empty-candidates-mounted-disable-set",
            settle {
                window.attachedSheet === emptyAlert.window
                    && emptyPopup.window === emptyAlert.window
                    && !emptySet.isEnabled && emptyPopup.isEnabled
            })
        _ = emptyPopup.sendAction(emptyPopup.action, to: emptyPopup.target)
        guard settle({ emptyAlert.window.attachedSheet?.isVisible == true }),
            let emptyPanel = emptyAlert.window.attachedSheet as? NSOpenPanel
        else {
            check("empty-candidates-choose-opens", false)
            finish()
        }
        check("empty-candidates-choose-opens", true)
        emptyPanel.cancel(nil)
        check(
            "empty-candidates-cancel-keeps-set-disabled",
            settle {
                emptyAlert.window.attachedSheet == nil && emptyPopup.isEnabled
                    && !emptySet.isEnabled
                    && emptyPopup.selectedItem?.representedObject == nil
            })
        // Callback-state control, not a claim that physical native picker acceptance was driven.
        let custom = root.appendingPathComponent("Fixture.app")
        emptyPopup.selectApplication(custom)
        check(
            "custom-callback-state-enables-set",
            emptySet.isEnabled
                && emptyPopup.selectedItem?.representedObject as? URL == custom)
        let customCount = emptyPopup.numberOfItems
        emptyPopup.selectApplication(custom)
        check("custom-callback-state-deduplicates", emptyPopup.numberOfItems == customCount)
        emptyPopup.selectItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))
        _ = emptyPopup.sendAction(emptyPopup.action, to: emptyPopup.target)
        guard settle({ emptyAlert.window.attachedSheet?.isVisible == true }),
            let customPanel = emptyAlert.window.attachedSheet as? NSOpenPanel
        else {
            check("custom-retry-opens", false)
            finish()
        }
        customPanel.cancel(nil)
        check(
            "custom-retry-cancel-restores-custom",
            settle {
                emptyAlert.window.attachedSheet == nil && emptySet.isEnabled
                    && emptyPopup.selectedItem?.representedObject as? URL == custom
            })
        window.endSheet(emptyAlert.window, returnCode: .alertSecondButtonReturn)
        check("empty-dialog-cleanup", settle { window.attachedSheet == nil })
        finish()
    }
}
#endif
