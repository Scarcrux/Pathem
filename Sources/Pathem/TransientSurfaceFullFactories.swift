#if DEBUG
import AppKit
import PathemEngine

extension TransientSurfaceSample {
    @MainActor
    final class FactoryObject {
        let alert: NSAlert?
        let save: NSSavePanel?
        let retained: AnyObject?
        let cancelIndex: Int?
        init(_ alert: NSAlert, cancel: Int? = 1, retained: AnyObject? = nil) {
            self.alert = alert
            self.save = nil
            self.retained = retained
            self.cancelIndex = cancel
        }
        init(save: NSSavePanel, retained: AnyObject?) {
            self.alert = nil
            self.save = save
            self.retained = retained
            self.cancelIndex = nil
        }
        var window: NSWindow { alert?.window ?? save! }
        var buttons: [NSButton] {
            if let alert { return alert.buttons }
            guard let content = window.contentView else { return [] }
            return TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }
        }
    }
    @MainActor
    final class Factory {
        let id: String
        let site: String
        let filename: Bool
        let sheet: Bool
        let make: (URL, String) -> FactoryObject
        init(
            id: String, site: String, filename: Bool, sheet: Bool,
            make: @escaping (URL, String) -> FactoryObject
        ) {
            self.id = id
            self.site = site
            self.filename = filename
            self.sheet = sheet
            self.make = make
        }
    }
    @MainActor
    final class FactoryObservation {
        var inspected = false
        var timedOut = false
        var nativeCancel = false
        var response: NSApplication.ModalResponse?
        let deadline = Date().addingTimeInterval(5)
    }

    func fullFactories() -> [Factory] {
        func factory(
            _ id: String, _ source: String, function: String, sheet: Bool = false,
            filename: Bool = true, _ make: @escaping (URL, String) -> FactoryObject
        ) -> Factory {
            let matches = policy.keys.filter { key in
                guard key.hasPrefix("Sources/Pathem/" + source + ":") else { return false }
                // Physical caller identity is specified by the audited factory map,
                // not guessed by NSAlert count or by a shared localized heading.
                return factorySites[id] == key
            }
            precondition(matches.count == 1, "missing factory site: " + id)
            return Factory(id: id, site: matches[0], filename: filename, sheet: sheet, make: make)
        }
        return [
            factory("f01", "TemplatesController.swift", function: "editorSheet") { _, name in
                let value = CreateTemplate(
                    id: "owned", name: name, entries: [name, "folder/" + name])
                return FactoryObject(TemplatesController.makeEditorDialog(value).0)
            },
            factory("f02", "ExternalCommandsController.swift", function: "editorSheet") { _, name in
                let value = ExternalCommand(
                    id: "owned", name: name, command: "printf owned-fixture")
                return FactoryObject(ExternalCommandsController.makeEditorDialog(value).0)
            },
            factory("f03", "PDFMarkupView.swift", function: "promptForText") { _, name in
                return FactoryObject(
                    PDFMarkupView.makeTextPrompt(title: L("markup.noteText", "Note"), initial: name)
                        .0)
            },
            factory("f04", "DocumentPreviewView.swift", function: "offerToSaveIfEdited") {
                _, name in
                FactoryObject(DocumentPreviewView.makeSaveChangesDialog(name: name), cancel: nil)
            },
            factory("f05", "FindInFilesController.swift", function: "replaceAll") { _, name in
                FactoryObject(FindInFilesController.makeReplaceConfirmation(query: name))
            },
            factory("f06", "ProcessViewerController.swift", function: "terminate") { _, name in
                FactoryObject(
                    ProcessViewerController.makeTerminateConfirmation(
                        name: name, pid: 42, force: false))
            },
            factory("f07", "ProcessViewerController.swift", function: "terminate") { _, name in
                FactoryObject(
                    ProcessViewerController.makeTerminateConfirmation(
                        name: name, pid: 42, force: true))
            },
            factory(
                "f08", "PathemApp.swift", function: "applicationShouldTerminate", filename: false
            ) { _, _ in
                FactoryObject(PathemApp.makeTransferQuitConfirmation())
            },
            factory("f09", "TorrentDrawerController.swift", function: "addMagnetTapped") {
                _, name in
                FactoryObject(
                    TorrentDrawerController.makeMagnetDialog(
                        prefill: "magnet:?xt=urn:btih:" + String(repeating: "0", count: 40) + "&dn="
                            + name
                    ).0)
            },
            factory("f10", "TorrentsWindowController.swift", function: "addMagnetTapped") {
                _, name in
                FactoryObject(
                    TorrentsWindowController.makeMagnetDialog(
                        prefill: "magnet:?xt=urn:btih:" + String(repeating: "0", count: 40) + "&dn="
                            + name
                    ).0)
            },
            factory("f11", "TorrentDrawerController.swift", function: "removeTapped", sheet: true) {
                _, name in
                FactoryObject(TorrentDrawerController.makeRemoveDialog(name: name), cancel: 2)
            },
            factory("f12", "TorrentsWindowController.swift", function: "removeTapped") { _, name in
                FactoryObject(TorrentsWindowController.makeRemoveDialog(name: name), cancel: 2)
            },
            factory(
                "f13", "BrowserViewController+Torrents.swift",
                function: "createTorrentFromSelection"
            ) { file, _ in
                FactoryObject(BrowserViewController.makeCreateTorrentDialog(source: file).0)
            },
            factory("f14", "BatchRenameController.swift", function: "saveCurrentAsPreset") {
                _, name in
                FactoryObject(BatchRenameController.makePresetDialog(prefill: name).0)
            },
            factory(
                "f15", "BrowserViewController+RemoteConnections.swift", function: "beginConnect",
                sheet: true
            ) { _, name in
                var connection = RemoteConnection(
                    name: "Owned fixture", proto: .sftp, host: name, user: "fixture")
                connection.keyFile = ""
                return FactoryObject(
                    BrowserViewController.makePasswordDialog(connection: connection).0)
            },
            factory(
                "f16", "BrowserViewController+RemoteConnections.swift", function: "beginConnect",
                sheet: true
            ) { _, name in
                var connection = RemoteConnection(
                    name: "Owned fixture", proto: .sftp, host: name, user: "fixture")
                connection.keyFile = "owned-key"
                return FactoryObject(
                    BrowserViewController.makePasswordDialog(connection: connection).0)
            },
            factory(
                "f17", "BrowserViewController+RemoteConnections.swift", function: "addBookmark",
                sheet: true
            ) { _, name in
                FactoryObject(
                    BrowserViewController.makeBookmarkDialog(
                        path: "/" + Array(repeating: name, count: 4).joined(separator: "/"),
                        connectionName: name
                    ).0)
            },
            factory(
                "f18", "BrowserViewController+Torrents.swift",
                function: "createTorrentFromSelection"
            ) { file, _ in
                let value = BrowserViewController.makeTorrentSaveDialog(
                    source: file, offerSuggestions: true, generateAutomatically: false)
                value.0.directoryURL = file.deletingLastPathComponent()
                return FactoryObject(save: value.0, retained: value.1)
            },
            factory(
                "f19", "TorrentLimitsSheet.swift", function: "present", sheet: true, filename: false
            ) { _, _ in
                FactoryObject(
                    TorrentLimitsSheet.makeDialog(
                        downLimit: 1_024_000, upLimit: 512_000, superSeedEnabled: true,
                        encryptOutgoing: true, preferUTP: true, bindToVPN: true,
                        vpnLine: L(
                            "torrents.vpn.killed",
                            "No VPN detected. Torrents paused to prevent leaks."), vpnMissing: true
                    ).0)
            },
            factory("f20", "TorrentLimitsSheet.swift", function: "present", filename: false) {
                _, _ in
                FactoryObject(
                    TorrentLimitsSheet.makeDialog(
                        downLimit: 1_024_000, upLimit: 512_000, superSeedEnabled: true,
                        encryptOutgoing: true, preferUTP: true, bindToVPN: true,
                        vpnLine: L(
                            "torrents.vpn.killed",
                            "No VPN detected. Torrents paused to prevent leaks."), vpnMissing: true
                    ).0)
            },
            factory(
                "f21", "TorrentsWindowController.swift", function: "limitsTapped", filename: false
            ) { _, _ in
                FactoryObject(
                    TorrentsWindowController.makeLimitsDialog(
                        downLimit: 1_024_000, upLimit: 512_000, superSeedEnabled: true,
                        encryptOutgoing: true, preferUTP: true, bindToVPN: true,
                        vpnLine: L(
                            "torrents.vpn.killed",
                            "No VPN detected. Torrents paused to prevent leaks."), vpnMissing: true
                    ).0)
            },
        ]
    }

    var factorySites: [String: String] {
        guard let path = environment["PATHEM_TRANSIENT_FACTORIES"],
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let recipes = object["factories"] as? [[String: Any]]
        else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: recipes.map { ($0["id"] as! String, $0["site"] as! String) })
    }

    func runFullFactories() {
        guard
            settle({
                self.browser.leftTabs.activePane != nil && self.browser.rightTabs.activePane != nil
            }),
            host.sheets.isEmpty, returnBindingControl()
        else {
            emit("factory-setup", 0, false, "initial browser/control missing")
            return
        }
        emit("predicate-startup", 0, true, "sheets=0 argumentOnlyFirstRunState=true")
        let group = Int(environment["PATHEM_TRANSIENT_SURFACES_GROUP"] ?? "0") ?? 0
        let one = environment["PATHEM_TRANSIENT_SURFACES_PROBE_ONE"] == "1"
        let selected = fullFactories().enumerated().filter {
            group == 0 || $0.offset / 6 + 1 == group
        }.map(\.element).filter { entry in
            environment["PATHEM_TRANSIENT_SURFACES_ONLY"].map { $0 == entry.id } ?? true
        }
        for appearance in (one ? [NSAppearance.Name.aqua] : [.aqua, .darkAqua]) {
            requestedAppearance = appearance
            host.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)
            for size
                in (one
                ? [NSSize(width: 720, height: 420)]
                : [NSSize(width: 720, height: 420), NSSize(width: 1100, height: 700)])
            {
                requestedSize = size
                host.setContentSize(size)
                for entry in (one ? Array(selected.prefix(1)) : selected) {
                    for long in entry.filename ? [false, true] : [false] {
                        let name =
                            long ? String(repeating: "n", count: 251) + ".txt" : "fixture.txt"
                        let cell =
                            "F-\(entry.id)-\(language)-\(appearance == .aqua ? "light" : "dark")-\(Int(size.width))-\(long ? "long255" : "short")"
                        runFactory(entry, cell: cell, name: name)
                    }
                }
            }
        }
        NSApp.appearance = nil
    }

    func inspectFactory(_ entry: Factory, object: FactoryObject, cell: String, cycle: Int) {
        let window = object.window
        guard let content = window.contentView else {
            emit(cell, 0, false, "native content missing")
            return
        }
        content.layoutSubtreeIfNeeded()
        emit(cell, 0, true, "cycle=\(cycle) factory=\(entry.id) site=\(entry.site)")
        inspect(
            content, alert: object.alert, cell: cell, phase: "cycle\(cycle)-factory",
            sheet: entry.sheet, presented: true)
        emit(
            cell, 4,
            (entry.sheet ? window.sheetParent === host : NSApp.modalWindow === window)
                && TransientSurfaceChecks.appearance(content, expected: requestedAppearance),
            "cycle=\(cycle) production factory; original presentation style", content: content)
        let buttons = object.buttons
        let expected =
            object.alert?.buttons.first ?? buttons.first { $0.cell === window.defaultButtonCell }
        let probe = TransientReturnBindingProbe.observe(window: window, buttons: buttons) {
            self.key("\r", window: window)
        }
        emit(
            cell, 6,
            probe.resolved
                && (expected.map { expected in
                    expected.isEnabled
                        ? (probe.accepted && probe.received.count == 1
                            && probe.received.first === expected)
                        : probe.received.isEmpty
                } ?? probe.received.isEmpty),
            "cycle=\(cycle) Return accepted=\(probe.accepted) received=\(probe.received.map(\.title)) production callback withheld",
            content: content)
        if cycle == 0 { capture(content, key: cell + "-initial") }
        if let suggestion = object.retained as? FilenameSuggestionController {
            suggestion.debugDeliver(
                String(repeating: "long suggested name ", count: 8), ext: "torrent")
            content.layoutSubtreeIfNeeded()
            inspect(
                content, alert: object.alert, cell: cell, phase: "cycle\(cycle)-suggestion",
                sheet: entry.sheet, presented: true)
            suggestion.debugFail()
            content.layoutSubtreeIfNeeded()
            inspect(
                content, alert: object.alert, cell: cell, phase: "cycle\(cycle)-suggestion-failure",
                sheet: entry.sheet, presented: true)
        }
    }

    func runFactory(_ entry: Factory, cell: String, name: String) {
        for cycle in 0..<3 {
            let directory = root.appendingPathComponent(cell + "-\(cycle)", isDirectory: true)
            let file = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try Data("Owned modal fixture".utf8).write(to: file)
            } catch {
                emit(cell, 0, false, "owned fixture unavailable")
                return
            }
            host.makeKeyAndOrderFront(nil)
            if let pane = browser.leftTabs.activePane { host.makeFirstResponder(pane.keyView) }
            let responder = host.firstResponder.map(ObjectIdentifier.init)
            let before = windows()
            let files = snapshot(directory)
            let object = entry.make(file, name)
            object.window.appearance = host.appearance
            object.alert?.layout()
            let state = FactoryObservation()
            if entry.sheet {
                object.alert!.beginSheetModal(for: host) { state.response = $0 }
                if settle({ object.window.isVisible && object.window.sheetParent === self.host }) {
                    inspectFactory(entry, object: object, cell: cell, cycle: cycle)
                    if let index = object.cancelIndex, object.buttons.indices.contains(index) {
                        object.buttons[index].performClick(nil)
                        state.nativeCancel = true
                    }
                    _ = settle { state.response != nil }
                } else {
                    emit(cell, 0, false, "native sheet not delivered")
                }
            } else {
                let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if Date() > state.deadline {
                            state.timedOut = true
                            NSApp.abortModal()
                            return
                        }
                        guard !state.inspected, object.window.isVisible else { return }
                        if let alert = object.alert {
                            guard
                                alert.buttons.contains(where: {
                                    $0.cell === object.window.defaultButtonCell
                                        || $0.keyEquivalent == "\r"
                                })
                            else { return }
                        }
                        object.window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        print(
                            "TSAMPLE: MODAL-READY cell=\(cell) key=\(object.window.isKeyWindow) default=\(object.window.defaultButtonCell != nil) modal=\(NSApp.modalWindow === object.window)"
                        )
                        state.inspected = true
                        self.inspectFactory(entry, object: object, cell: cell, cycle: cycle)
                        if let save = object.save {
                            save.cancel(nil)
                            state.nativeCancel = true
                        } else if let index = object.cancelIndex,
                            object.buttons.indices.contains(index)
                        {
                            object.buttons[index].performClick(nil)
                            state.nativeCancel = true
                        } else {
                            // Record lack of a non-mutating Cancel, then retire only
                            // this fixture's modal session. Do not call Discard.
                            _ = self.key("\u{1b}", window: object.window)
                            NSApp.abortModal()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                RunLoop.main.add(timer, forMode: .default)
                state.response = object.alert?.runModal() ?? object.save!.runModal()
                timer.invalidate()
            }
            let expected =
                object.save != nil
                ? NSApplication.ModalResponse.cancel
                : object.cancelIndex.map { NSApplication.ModalResponse(rawValue: 1000 + $0) }
            emit(
                cell, 5,
                state.nativeCancel && state.response == expected && snapshot(directory) == files,
                "cycle=\(cycle) Cancel exists=\(object.save != nil || object.cancelIndex != nil) response=\(String(describing: state.response?.rawValue)) owned files unchanged=\(snapshot(directory) == files)",
                content: object.window.contentView)
            let dismissed = settle {
                !object.window.isVisible && self.host.attachedSheet !== object.window
            }
            emit(
                cell, 7,
                !state.timedOut && dismissed
                    && host.firstResponder.map(ObjectIdentifier.init) == responder,
                "cycle=\(cycle) dismissed=\(dismissed) timedOut=\(state.timedOut)",
                content: object.window.contentView)
            emit(
                cell, 8, TransientSurfaceChecks.noAccumulation(before: before, after: windows()),
                "cycle=\(cycle) before=\(before) after=\(windows())",
                content: object.window.contentView)
            if !dismissed {
                if object.window.sheetParent === host { host.endSheet(object.window) }
                object.window.orderOut(nil)
            }
            (object.retained as? FilenameSuggestionController)?.cancel()
        }
        print("TSAMPLE: COVERED class=A site=\(entry.site) cell=\(cell)")
    }
}
#endif
