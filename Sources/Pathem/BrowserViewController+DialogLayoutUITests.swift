#if DEBUG
import AppKit

extension BrowserViewController {
    /// Exercise the complete native alert, including AppKit's reserved message/button space.
    /// Checking the accessory alone missed the zero-frame Rename regression.
    func checkDialogLayout(check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool) {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func alignedRect(_ view: NSView, in content: NSView) -> NSRect {
            guard let parent = view.superview else { return .zero }
            return content.convert(view.alignmentRect(forFrame: view.frame), from: parent)
        }
        func contained(_ view: NSView, in parent: NSView) -> Bool {
            // NSTextField's decorative frame extends two points beyond its alignment rect.
            // Validate the allocated control area, not native focus-ring/shadow decoration.
            let rect = alignedRect(view, in: parent)
            return rect.width > 2 && rect.height > 2
                && parent.bounds.insetBy(dx: -1, dy: -1).contains(rect)
        }
        func separated(_ views: [NSView], in content: NSView) -> Bool {
            let rects = views.map { alignedRect($0, in: content) }
            return rects.enumerated().allSatisfy { index, rect in
                rect.width > 2 && rect.height > 2
                    && rects.dropFirst(index + 1).allSatisfy { !rect.intersects($0) }
            }
        }
        func textFits(_ label: NSTextField) -> Bool {
            guard let cell = label.cell else { return false }
            let needed = cell.cellSize(
                forBounds: NSRect(
                    x: 0, y: 0, width: label.bounds.width,
                    height: CGFloat.greatestFiniteMagnitude))
            return label.bounds.height + 2 >= needed.height
        }
        func inspect(_ alert: NSAlert, controls: [NSView], name: String) {
            guard let content = alert.window.contentView, let accessory = alert.accessoryView else {
                check("dialog-\(name)-native-content", false)
                return
            }
            content.layoutSubtreeIfNeeded()
            let labels = descendants(content).compactMap { $0 as? NSTextField }.filter { label in
                !label.isEditable && !label.isHiddenOrHasHiddenAncestor
                    && (label.stringValue == alert.messageText
                        || label.stringValue == alert.informativeText)
                    && !label.stringValue.isEmpty
                    // NSButton owns a title field; do not count it twice when its title
                    // happens to equal the alert message (for example, Rename).
                    && !alert.buttons.contains { label.isDescendant(of: $0) }
            }
            let nativeControls: [NSView] = labels + alert.buttons
            check("dialog-\(name)-native-message-delivered", !labels.isEmpty)
            check(
                "dialog-\(name)-accessory-reserved",
                contained(accessory, in: content) && accessory.bounds.width >= 280
                    && accessory.bounds.width <= 540)
            check(
                "dialog-\(name)-controls-contained",
                controls.allSatisfy { contained($0, in: accessory) && contained($0, in: content) }
                    && nativeControls.allSatisfy { contained($0, in: content) })
            check(
                "dialog-\(name)-whole-sheet-separated",
                separated(controls + nativeControls, in: content))
            check(
                "dialog-\(name)-native-text-fits",
                labels.allSatisfy(textFits))
            print(
                "DIALOGRECEIPT name=\(name) sheet=\(content.bounds) accessory=\(accessory.convert(accessory.bounds, to: content)) controls=\(controls.map { alignedRect($0, in: content) })"
            )
            if !separated(controls + nativeControls, in: content) {
                print(
                    "DIALOGCHROME name=\(name) labels=\(labels.map { ($0.stringValue, alignedRect($0, in: content)) }) buttons=\(alert.buttons.map { alignedRect($0, in: content) })"
                )
            }
        }
        func present(_ alert: NSAlert, over host: NSWindow) -> Bool {
            // Tests replace translated chrome after the factory has materialized its window.
            // Production supplies all chrome before touching alert.window.
            alert.layout()
            alert.beginSheetModal(for: host) { _ in }
            return settle {
                host.attachedSheet === alert.window && alert.window.isVisible
                    && alert.window.contentView != nil
            }
        }
        func dismiss(_ alert: NSAlert, from host: NSWindow, name: String) {
            host.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            alert.window.orderOut(nil)
            check("dialog-\(name)-cancel-terminal", settle { host.attachedSheet == nil })
        }

        // The real geometry predicate must reject both failure modes, not merely accept every sheet.
        let controlHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        let first = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let second = NSTextField(frame: NSRect(x: 0, y: 40, width: 300, height: 24))
        controlHost.addSubview(first)
        controlHost.addSubview(second)
        check(
            "dialog-geometry-known-good-control",
            contained(first, in: controlHost) && contained(second, in: controlHost)
                && separated([first, second], in: controlHost))
        first.setFrameOrigin(NSPoint(x: 180, y: 0))
        check("dialog-geometry-clipping-negative-control", !contained(first, in: controlHost))
        first.frame = second.frame
        check(
            "dialog-geometry-overlap-negative-control",
            !separated([first, second], in: controlHost))

        let names = ["fixture.txt", String(repeating: "long-name-", count: 25) + "résumé.txt"]
        var captured = false
        let messages = [
            ("Rename", "Enter a new name for this item."),
            ("Datei umbenennen", "Geben Sie einen neuen Namen für dieses ausgewählte Objekt ein."),
            ("名前を変更", "この項目の新しい名前を入力してください。"),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.appearance = NSAppearance(named: appearance)
            host.makeKeyAndOrderFront(nil)
            defer { host.orderOut(nil) }
            for (nameIndex, original) in names.enumerated() {
                for offersSuggestions in [false, true] {
                    let token = "rename-\(appearance.rawValue)-\(nameIndex)-\(offersSuggestions)"
                    let dialog = RenameDialogController(
                        name: original, url: URL(fileURLWithPath: "/fixture/placeholder.txt"),
                        dataless: false, offerSuggestions: offersSuggestions,
                        generateAutomatically: false)
                    dialog.alert.window.appearance = NSAppearance(named: appearance)
                    // Translated-sized native chrome is part of the same whole-sheet test.
                    let message = messages[
                        (nameIndex + (offersSuggestions ? 1 : 0)) % messages.count]
                    dialog.alert.messageText = message.0
                    dialog.alert.informativeText = message.1
                    check("dialog-\(token)-actual-sheet", present(dialog.alert, over: host))
                    var controls: [NSView] = [dialog.field]
                    if let suggestion = dialog.suggestion {
                        controls += [suggestion.debugLabel, suggestion.debugButton]
                    }
                    inspect(dialog.alert, controls: controls, name: token + "-initial")
                    check("dialog-\(token)-initial-name", dialog.field.stringValue == original)
                    dialog.alert.window.makeFirstResponder(dialog.field)
                    let editor = dialog.field.currentEditor() as? NSTextView
                    dialog.field.stringValue = "typed-before-response.txt"
                    editor?.string = "typed-before-response.txt"
                    editor?.setSelectedRange(NSRange(location: 6, length: 0))
                    check("dialog-\(token)-editor-delivered", editor != nil)
                    let typed = editor?.string ?? dialog.field.stringValue
                    let caret = editor?.selectedRange()
                    let responder = dialog.alert.window.firstResponder
                    if let suggestion = dialog.suggestion {
                        suggestion.debugDeliver(
                            String(repeating: "long suggested name ", count: 8), ext: "txt")
                        check(
                            "dialog-\(token)-long-suggestion-delivered",
                            settle {
                                suggestion.debugButton.isEnabled
                                    && suggestion.debugLabel.stringValue.count > 100
                            })
                        inspect(dialog.alert, controls: controls, name: token + "-long-success")
                        check(
                            "dialog-\(token)-long-suggestion-text-fits",
                            textFits(suggestion.debugLabel))
                        if !captured,
                            let capturePath = ProcessInfo.processInfo.environment[
                                "PATHEM_DIALOG_CAPTURE_PATH"],
                            let content = dialog.alert.window.contentView,
                            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                        {
                            content.cacheDisplay(in: content.bounds, to: bitmap)
                            if let png = bitmap.representation(using: .png, properties: [:]) {
                                do {
                                    try png.write(to: URL(fileURLWithPath: capturePath))
                                    captured = true
                                } catch { check("dialog-optional-screenshot-written", false) }
                            }
                        }
                        check(
                            "dialog-\(token)-response-preserves-editing",
                            editor?.string == typed && editor?.selectedRange() == caret
                                && dialog.alert.window.firstResponder === responder)
                        suggestion.debugFail()
                        check(
                            "dialog-\(token)-failure-disables-use",
                            !suggestion.debugButton.isEnabled
                                && !suggestion.debugLabel.stringValue.isEmpty)
                        inspect(dialog.alert, controls: controls, name: token + "-failure")
                        check("dialog-\(token)-failure-text-fits", textFits(suggestion.debugLabel))
                        check(
                            "dialog-\(token)-failure-preserves-editing",
                            editor?.string == typed && editor?.selectedRange() == caret
                                && dialog.alert.window.firstResponder === responder)
                        suggestion.debugUse()
                        check(
                            "dialog-\(token)-failed-suggestion-cannot-apply",
                            editor?.string == typed && dialog.field.stringValue == typed)
                        suggestion.debugDeliver("accepted-fixture-name", ext: "txt")
                        suggestion.debugUse()
                        check(
                            "dialog-\(token)-explicit-use",
                            dialog.field.stringValue == "accepted-fixture-name.txt")
                    }
                    dismiss(dialog.alert, from: host, name: token)
                    let finalValue = dialog.field.stringValue
                    dialog.cancel()
                    dialog.suggestion?.debugDeliver("stale-after-close", ext: "pdf")
                    dialog.suggestion?.debugUse()
                    check(
                        "dialog-\(token)-cancel-rejects-stale",
                        dialog.field.stringValue == finalValue)
                }
            }
            for (index, title) in ["Choose…", "Auswählen…", "選択…", "Choisir…", "Elegir…", "选择…"]
                .enumerated()
            {
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 32))
                let field = NSTextField(string: String(repeating: "/long-fixture-path", count: 20))
                let button = NSButton(title: title, target: nil, action: nil)
                button.bezelStyle = .rounded
                let row = ConnectionsController.pathChooserRow(field: field, button: button)
                row.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
                let rowWindow = NSWindow(
                    contentRect: container.bounds, styleMask: [.titled], backing: .buffered,
                    defer: false)
                rowWindow.isReleasedWhenClosed = false
                rowWindow.appearance = NSAppearance(named: appearance)
                rowWindow.contentView = container
                rowWindow.makeKeyAndOrderFront(nil)
                container.layoutSubtreeIfNeeded()
                check(
                    "dialog-connection-path-\(appearance.rawValue)-\(index)-contained",
                    contained(field, in: container) && contained(button, in: container)
                        && separated([field, button], in: container))
                check(
                    "dialog-connection-path-\(appearance.rawValue)-\(index)-usable",
                    field.bounds.width >= 80 && button.bounds.width + 1 >= button.fittingSize.width)
                rowWindow.orderOut(nil)
            }
            let commands = [
                (id: "fixture.short", title: "Open"),
                (
                    id: "fixture.long",
                    title: String(repeating: "Ausgewählten Ordner öffnen ", count: 8)
                ),
                (id: "fixture.japanese", title: "選択したすべてのファイルを別のアプリケーションで開く"),
            ]
            let commander = SettingsWindowController.makeCommanderKeysDialog(
                commands: commands, current: Array(repeating: "fixture.long", count: 6))
            commander.alert.window.appearance = NSAppearance(named: appearance)
            check(
                "dialog-commander-\(appearance.rawValue)-actual-sheet",
                present(commander.alert, over: host))
            let commanderLabels =
                commander.alert.accessoryView.map { accessory in
                    descendants(accessory).compactMap { $0 as? NSTextField }.filter {
                        !$0.isEditable
                            && ["F3", "F4", "F5", "F6", "F7", "F8"].contains($0.stringValue)
                    }
                } ?? []
            inspect(
                commander.alert, controls: commanderLabels + commander.popups,
                name: "commander-\(appearance.rawValue)")
            check(
                "dialog-commander-\(appearance.rawValue)-six-functional-popups",
                commander.popups.count == 6
                    && commander.popups.allSatisfy {
                        $0.numberOfItems == commands.count
                            && ($0.selectedItem?.representedObject as? String) == "fixture.long"
                    })
            dismiss(commander.alert, from: host, name: "commander-\(appearance.rawValue)")

            // The same suggestion accessory is used by the torrent Save panel. Cancel only:
            // no selected source, output file, preference, daemon, or owner window is involved.
            let save = NSSavePanel()
            save.appearance = NSAppearance(named: appearance)
            save.nameFieldStringValue = "fixture.torrent"
            save.directoryURL = FileManager.default.temporaryDirectory
            save.canCreateDirectories = false
            save.showsTagField = false
            let field = NSTextField(string: save.nameFieldStringValue)
            let suggestion = FilenameSuggestionController(
                field: field, url: URL(fileURLWithPath: "/fixture/placeholder.txt"),
                dataless: false, extensionOverride: "torrent", generateAutomatically: false)
            suggestion.onApply = { [weak save] name in save?.nameFieldStringValue = name }
            save.accessoryView = suggestion.view
            var saveResponse: NSApplication.ModalResponse?
            save.beginSheetModal(for: host) { saveResponse = $0 }
            check(
                "dialog-save-\(appearance.rawValue)-actual-sheet",
                settle {
                    // Save panels host custom content in an NSAccessoryViewWindow, not in
                    // the NSSavePanel window itself. Require both actual windows visible.
                    host.attachedSheet === save && save.isVisible
                        && suggestion.view.window?.isVisible == true
                })
            suggestion.debugDeliver(
                String(repeating: "long suggested name ", count: 8), ext: "torrent")
            save.contentView?.layoutSubtreeIfNeeded()
            check(
                "dialog-save-\(appearance.rawValue)-suggestion-contained",
                save.contentView.map { content in
                    contained(suggestion.view, in: content)
                        && contained(suggestion.debugLabel, in: suggestion.view)
                        && contained(suggestion.debugButton, in: suggestion.view)
                        && separated([suggestion.debugLabel, suggestion.debugButton], in: content)
                        && textFits(suggestion.debugLabel)
                } ?? false)
            check(
                "dialog-save-\(appearance.rawValue)-no-implicit-name-write",
                save.nameFieldStringValue == "fixture.torrent")
            suggestion.debugDeliver("accepted-save-name", ext: "torrent")
            suggestion.debugUse()
            check(
                "dialog-save-\(appearance.rawValue)-explicit-use",
                save.nameFieldStringValue == "accepted-save-name.torrent")
            save.cancel(nil)
            check(
                "dialog-save-\(appearance.rawValue)-cancel-terminal",
                settle { host.attachedSheet == nil && saveResponse == .cancel })
            suggestion.cancel()
            suggestion.debugDeliver("stale-save", ext: "torrent")
            suggestion.debugUse()
            check(
                "dialog-save-\(appearance.rawValue)-cancel-rejects-stale",
                save.nameFieldStringValue == "accepted-save-name.torrent")
        }
    }
}
#endif
