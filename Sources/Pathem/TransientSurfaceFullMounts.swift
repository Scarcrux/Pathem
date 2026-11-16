#if DEBUG
import AppKit
import PathemEngine
import TorrentKit

extension TransientSurfaceSample {
    @MainActor
    final class MountOwners {
        var values: [String: AnyObject] = [:]
        func get<T: AnyObject>(_ id: String, make: () -> T) -> T {
            if let value = values[id] as? T { return value }
            let value = make()
            values[id] = value
            return value
        }
    }
    struct Mount {
        let id: String
        let site: String
        let filename: Bool
        let show: (URL, String) -> AnyObject?
        let reset: () -> Void
        let prepare: (URL, String) -> Void
    }

    func fullMounts() -> [Mount] {
        let owners = MountOwners()
        func mount(
            _ id: String, _ source: String, filename: Bool = false,
            prepare: @escaping (URL, String) -> Void = { _, _ in },
            _ show: @escaping (URL, String) -> AnyObject?
        ) -> Mount {
            let matches = policy.keys.filter { $0.hasPrefix("Sources/Pathem/" + source + ":") }
            precondition(matches.count == 1, "explicit presentation site must be unique: " + source)
            return Mount(
                id: id, site: matches[0], filename: filename, show: show,
                reset: { owners.values.removeAll() }, prepare: prepare)
        }
        let b = browser
        return [
            mount("m01", "BrowserViewController+DynamicMenus.swift:180") { _, _ in
                b.saveLayoutPrompt()
                return b
            },
            mount("m02", "BrowserViewController+FolderBackground.swift:32", filename: true) {
                _, _ in
                b.setFolderBackgroundColor()
                return b
            },
            mount("m03", "BrowserViewController+Permissions.swift:48") { _, _ in
                b.changeOwnerViaTerminal()
                return b
            },
            mount("m04", "BrowserViewController+Servers.swift:23") { _, _ in
                b.connectToServer()
                return b
            },
            mount("m05", "BrowserViewController+ViewPresets.swift:47") { _, _ in
                b.saveViewPreset()
                return b
            },
            mount("m06", "BrowserViewController+SmartFolders.swift:171") { _, _ in
                b.showAdvancedFind()
                return b
            },
            mount("m07", "BrowserViewController+ViewOptions.swift:12", filename: true) { _, _ in
                b.showViewOptions()
                return b
            },
            mount("m08", "BrowserViewController+SelectionInspection.swift:250", filename: true) {
                _, _ in
                b.setFinderCommentSelection()
                return b
            },
            mount("m09", "BrowserViewController+MediaTools.swift:158") { _, _ in
                b.removeLocationFromSelection()
                return b
            },
            mount("m10", "BrowserViewController+MediaTools.swift:369") { _, _ in
                b.convertImagesSelection()
                return b
            },
            mount("m11", "BrowserViewController+OpenerRules.swift:87", filename: true) { _, _ in
                b.setDefaultOpener(nil)
                return b
            },
            mount("m12", "BrowserViewController+SelectionTransforms.swift:271", filename: true) {
                _, _ in
                b.encryptToDiskImage()
                return b
            },
            mount("m13", "BrowserViewController+SelectionTransforms.swift:318", filename: true) {
                _, _ in
                b.secureDeleteSelection()
                return b
            },
            mount("m14", "ACLEditorController.swift:42", filename: true) { file, _ in
                let controller = owners.get("m14") { ACLEditorController() }
                controller.present(url: file, over: self.host)
                return controller
            },
            mount("m15", "AICommandBar.swift:132") { _, _ in
                let controller = owners.get("m15") { AICommandBar() }
                controller.present(
                    over: self.host, resolve: { _ in nil },
                    run: { _ in self.emit("mount-callback", 5, false, "unexpected AI command") })
                return controller
            },
            mount("m16", "ArchiveContentsController.swift:31", filename: true) { _, name in
                let controller = owners.get("m16") { ArchiveContentsController() }
                controller.present(
                    over: self.host, archiveName: name, entries: [name],
                    onExtractAll: { self.emit("mount-callback", 5, false, "unexpected extraction") }
                )
                return controller
            },
            mount("m17", "BatchCreateController.swift:39") { _, _ in
                let controller = owners.get("m17") { BatchCreateController() }
                controller.present(
                    over: self.host,
                    create: { _, _ in self.emit("mount-callback", 5, false, "unexpected creation")
                    },
                    saveTemplate: { _, _ in
                        self.emit("mount-callback", 5, false, "unexpected template save")
                    })
                return controller
            },
            mount("m18", "BatchRenameController.swift:198", filename: true) { file, name in
                let controller = owners.get("m18") { BatchRenameController() }
                controller.present(
                    names: [name], in: file.deletingLastPathComponent(), existing: [name],
                    over: self.host,
                    onComplete: { self.emit("mount-callback", 5, false, "unexpected rename") })
                return controller
            },
            mount("m19", "BulkAttributesController.swift:36") { _, _ in
                let controller = owners.get("m19") { BulkAttributesController() }
                controller.present(
                    count: 999999, over: self.host,
                    onApply: { _ in
                        self.emit("mount-callback", 5, false, "unexpected attributes write")
                    })
                return controller
            },
            mount("m20", "ClipboardViewerController.swift:37", filename: true) { file, _ in
                let controller = owners.get("m20") { ClipboardViewerController() }
                controller.present(
                    items: [file], isCut: true, over: self.host,
                    onPaste: { self.emit("mount-callback", 5, false, "unexpected paste") },
                    onClear: { self.emit("mount-callback", 5, false, "unexpected clipboard clear") }
                )
                return controller
            },
            mount("m21", "CommandPalette.swift:125") { _, _ in
                let controller = owners.get("m21") { CommandPalette() }
                controller.present(
                    commands: [("fixture", "Fixture command")], prefill: ">",
                    onRun: { _ in self.emit("mount-callback", 5, false, "unexpected command") },
                    onNavigate: { _ in
                        self.emit("mount-callback", 5, false, "unexpected navigation")
                    }, onSemantic: { _ in }, over: self.host)
                return controller
            },
            mount("m22", "CommitController.swift:36", filename: true) { _, name in
                let controller = owners.get("m22") { CommitController() }
                controller.present(
                    over: self.host, repo: name, canSuggest: false, suggest: { nil },
                    commit: { _ in self.emit("mount-callback", 5, false, "unexpected commit") })
                return controller
            },
            mount("m23", "ConnectionsController.swift:151") { _, _ in
                let controller = owners.get("m23") { ConnectionsController() }
                controller.connections = []
                controller.present(over: self.host)
                return controller
            },
            mount("m24", "ExternalCommandsController.swift:33") { _, _ in
                let controller = owners.get("m24") { ExternalCommandsController() }
                controller.present(
                    over: self.host, commands: [],
                    onChange: { _ in
                        self.emit("mount-callback", 5, false, "unexpected command edit")
                    }, onRun: { _ in self.emit("mount-callback", 5, false, "unexpected command") })
                return controller
            },
            mount("m25", "FindInFilesController.swift:76", filename: true) { _, name in
                let controller = owners.get("m25") { FindInFilesController() }
                controller.present(
                    over: self.host, folderName: name, search: { _, _, _ in [] },
                    open: { _ in self.emit("mount-callback", 5, false, "unexpected file open") },
                    replace: { _, _, _, _ in
                        ContentSearch.ReplaceResult(filesChanged: 0, replacements: 0)
                    })
                return controller
            },
            mount("m26", "GlobalSearchController.swift:85") { file, _ in
                let controller = owners.get("m26") { GlobalSearchController() }
                controller.present(
                    over: self.host, currentFolder: file.deletingLastPathComponent(),
                    onReveal: { _ in },
                    onOpen: { _ in self.emit("mount-callback", 5, false, "unexpected file open") })
                return controller
            },
            mount("m27", "InfoInspectorController.swift:214", filename: true) { file, _ in
                let controller = owners.get("m27") { InfoInspectorController() }
                controller.present(urls: [file], over: self.host)
                return controller
            },
            mount("m28", "OrganizeReviewController.swift:59", filename: true) { file, name in
                let controller = OrganizeReviewController(
                    feedbackURL: file.deletingLastPathComponent().appendingPathComponent(
                        "feedback.json"))
                controller.present(
                    suggestions: [], folderName: name, destinations: FilingDestinations(),
                    over: self.host,
                    onApply: { _ in self.emit("mount-callback", 5, false, "unexpected organization")
                    })
                return controller
            },
            mount("m29", "TemplatesController.swift:34") { _, _ in
                let controller = owners.get("m29") { TemplatesController() }
                controller.present(
                    over: self.host, templates: [],
                    onChange: { _ in
                        self.emit("mount-callback", 5, false, "unexpected template edit")
                    },
                    onRun: { _ in self.emit("mount-callback", 5, false, "unexpected template run") }
                )
                return controller
            },
            mount("m30", "UndoHistoryController.swift:34") { _, _ in
                let controller = owners.get("m30") { UndoHistoryController() }
                controller.present(over: self.host, history: ActionHistory())
                return controller
            },
            mount("m31", "XattrController.swift:35", filename: true) { file, _ in
                let controller = owners.get("m31") { XattrController() }
                controller.present(for: file, over: self.host)
                return controller
            },
            mount("m32", "AutomationRulesController.swift:30") { _, _ in
                let controller = owners.get("m32") { AutomationRulesController() }
                controller.present(manager: AutomationManager(storeURL: nil), over: self.host)
                return controller
            },
            mount("m33", "ChangelogWindowController.swift:42") { _, _ in
                let controller = ChangelogWindowController.shared
                controller.present()
                return controller
            },
            mount("m34", "CropController.swift:61", filename: true) { file, _ in
                let controller = owners.get("m34") { CropController() }
                controller.present(url: file, over: self.host)
                return controller
            },
            mount("m35", "CropController.swift:63", filename: true) { file, _ in
                let controller = owners.get("m35") { CropController() }
                controller.present(url: file, over: nil)
                return controller
            },
            mount("m36", "DiffViewerController.swift:32", filename: true) { file, name in
                let other = file.deletingLastPathComponent().appendingPathComponent("other.txt")
                let controller = owners.get("m36") { DiffViewerController() }
                controller.present(left: file, right: other, over: self.host)
                return controller
            },
            mount("m37", "DuplicatesController.swift:37:27", filename: true) { file, _ in
                let controller = owners.get("m37") { DuplicatesController() }
                controller.onTrash = { _ in
                    self.emit("mount-callback", 5, false, "unexpected duplicate Trash")
                }
                controller.present(root: file.deletingLastPathComponent(), over: self.host)
                return controller
            },
            mount("m38", "DuplicatesController.swift:37:69", filename: true) { file, _ in
                let controller = owners.get("m38") { DuplicatesController() }
                controller.present(root: file.deletingLastPathComponent(), over: nil)
                return controller
            },
            mount("m39", "MetadataEditorController.swift:54:27", filename: true) { file, _ in
                let controller = owners.get("m39") { MetadataEditorController() }
                controller.present(urls: [file], over: self.host)
                return controller
            },
            mount("m40", "MetadataEditorController.swift:54:69", filename: true) { file, _ in
                let controller = owners.get("m40") { MetadataEditorController() }
                controller.present(urls: [file], over: nil)
                return controller
            },
            mount("m41", "MarkupController.swift:35", filename: true) { file, _ in
                let controller = owners.get("m41") { MarkupController() }
                controller.onSaved = { _ in
                    self.emit("mount-callback", 5, false, "unexpected markup save")
                }
                controller.markup(file)
                return controller
            },
            mount("m42", "ProcessViewerController.swift:36") { _, _ in
                let controller = owners.get("m42") { ProcessViewerController() }
                controller.present()
                return controller
            },
            mount("m43", "SizeBrowserController.swift:38", filename: true) { file, _ in
                let controller = owners.get("m43") { SizeBrowserController() }
                controller.present(for: file.deletingLastPathComponent(), over: self.host)
                return controller
            },
            mount("m44", "SelectByPatternSheet.swift:66") { _, _ in
                SelectByPatternSheet.present(over: self.host) { _, _ in
                    self.emit("mount-callback", 5, false, "unexpected selection edit")
                }
                return nil
            },
            mount("m45", "TransferProgress.swift:119", filename: true) { _, name in
                let controller = owners.get("m45") { TransferProgress() }
                controller.begin(verb: name, over: self.host) { controller.end() }
                return controller
            },
            mount("m46", "TransferProgress.swift:121", filename: true) { _, name in
                let controller = owners.get("m46") { TransferProgress() }
                controller.begin(verb: name, over: nil) { controller.end() }
                return controller
            },
            mount("m47", "ExternalCommandOutputController.swift:78", filename: true) { _, name in
                let controller = owners.get("m47") { ExternalCommandOutputController() }
                controller.present(title: name, loading: name) { "Owned completed output" }
                return controller
            },
            mount("m48", "ExternalCommandOutputController.swift:102", filename: true) { _, name in
                let controller = owners.get("m48") { ExternalCommandOutputController() }
                controller.run(title: name) {
                    ExternalCommandRunner.Output(text: "Owned completed output", exitCode: 0)
                }
                return controller
            },
            mount("m49", "TransferQueueController.swift:102", filename: true) { _, name in
                let controller = owners.get("m49") { TransferQueueController() }
                controller.run([.init(name: name, run: {})], title: name, over: self.host) {
                    failures, cancelled in
                    self.emit(
                        "mount-work", 0, failures.isEmpty && !cancelled,
                        "owned no-op queue job completed")
                }
                return controller
            },
            mount("m50", "TransferQueueController.swift:109") { _, _ in
                let controller = owners.get("m50") { TransferQueueController() }
                controller.showWindow()
                return controller
            },
            mount("m51", "SettingsWindowController.swift:196") { _, _ in
                let controller = owners.get("m51") { SettingsWindowController() }
                controller.present(
                    prefs: Preferences(), commands: [], effective: [:], gestures: [:],
                    updater: nil,
                    terminal: SettingsWindowController.TerminalOptions(
                        themes: ["Dark", "Light"], current: "Dark", follows: true,
                        onSelectTheme: { _ in }, onToggleFollows: { _ in }), over: self.host,
                    onChange: { _ in
                        self.emit("mount-callback", 5, false, "unexpected preference edit")
                    },
                    onKeymapChange: { _ in
                        self.emit("mount-callback", 5, false, "unexpected keymap edit")
                    },
                    onGestureChange: { _ in
                        self.emit("mount-callback", 5, false, "unexpected gesture edit")
                    })
                return controller
            },
            mount("m52", "SettingsWindowController.swift:1823") { _, _ in
                let controller = owners.get("m52") { SettingsWindowController() }
                _ = controller.debugPresentLive()
                return controller
            },
            mount("m53", "BrowserViewController+SheetHelpers.swift:29", filename: true) { _, name in
                Task { @MainActor in
                    let value = await b.promptForName(
                        title: L("bvc.saveStyleTitle", "Save style as:"), default: name)
                    self.emit("mount-work", 0, value == nil, "owned prompt cancelled")
                }
                return b
            },
            mount("m54", "BrowserViewController+FolderCompare.swift:39", filename: true) {
                file, name in
                b.presentCompare([], leftURL: file.deletingLastPathComponent(), rightURL: file)
                return b
            },
            mount("m55", "BrowserViewController.swift:931") { _, _ in
                // Return target/action is intercepted; only the real Cancel executes.
                b.resetPathemData()
                return b
            },
            mount(
                "m56", "BrowserViewController+Workspaces.swift:37", filename: true,
                prepare: { _, name in
                    if let pane = b.activePane {
                        b.windowState.saveStyle(
                            WindowStateStore.Style(name: name, format: pane.format))
                    }
                }
            ) { _, _ in
                b.applyStyle()
                return b
            },
            mount(
                "m57", "BrowserViewController+Workspaces.swift:86", filename: true,
                prepare: { file, name in
                    let folder = file.deletingLastPathComponent().path
                    b.windowState.saveWorkspace(
                        WindowStateStore.Workspace(
                            name: name, left: [folder], leftActive: 0, right: [folder],
                            rightActive: 0))
                }
            ) { _, _ in
                b.openWorkspace()
                return b
            },
            mount("m58", "WindowManager.swift:84") { file, _ in
                WindowManager.shared.openWindow(start: file.deletingLastPathComponent())
            },
            mount("m59", "SlideshowController.swift:40", filename: true) { file, _ in
                let controller = owners.get("m59") { SlideshowController() }
                controller.start(urls: [file])
                return controller
            },
            mount("m60", "TorrentFilesController.swift:32", filename: true) { _, name in
                let controller = owners.get("m60") { TorrentFilesController() }
                let files = try! JSONDecoder().decode(
                    [TorrentSession.FileInfo].self,
                    from: JSONSerialization.data(withJSONObject: [
                        ["index": 0, "path": name, "length": 1_048_576, "wanted": true]
                    ]))
                controller.present(name: name, files: files, over: self.host) { _ in
                    self.emit("mount-callback", 5, false, "unexpected torrent file selection")
                }
                return controller
            },
            mount("m61", "TorrentFilesController.swift:35", filename: true) { _, name in
                let controller = owners.get("m61") { TorrentFilesController() }
                let files = try! JSONDecoder().decode(
                    [TorrentSession.FileInfo].self,
                    from: JSONSerialization.data(withJSONObject: [
                        ["index": 0, "path": name, "length": 1_048_576, "wanted": true]
                    ]))
                controller.present(name: name, files: files, over: nil) { _ in
                    self.emit("mount-callback", 5, false, "unexpected torrent file selection")
                }
                return controller
            },
            mount("m62", "ExternalCommandOutputController.swift:37", filename: true) { file, name in
                let controller = owners.get("m62") { ExternalCommandOutputController() }
                // Literal command only; never interpolate filenames or owner commands.
                controller.run(
                    ExternalCommand(id: "owned", name: name, command: "printf owned-fixture"),
                    files: [], directory: file.deletingLastPathComponent())
                return controller
            },
        ]
    }

    func runFullMounts() {
        guard
            settle({
                self.browser.leftTabs.activePane != nil && self.browser.rightTabs.activePane != nil
            })
        else {
            emit("mount-setup", 0, false, "demo initial tabs never delivered")
            return
        }
        let startupOK =
            host.sheets.isEmpty
            && UserDefaults.standard.bool(forKey: BrowserViewController.demoOfferedKey)
            && UserDefaults.standard.bool(forKey: "pathem.fdaGuideDismissed")
        emit(
            "predicate-startup", 0, startupOK,
            "sheets=\(host.sheets.count) argumentOnlyFirstRunState=true")
        guard startupOK else { return }
        guard returnBindingControl() else { return }
        let group = Int(environment["PATHEM_TRANSIENT_SURFACES_GROUP"] ?? "0") ?? 0
        let groupedMounts = fullMounts().enumerated().filter {
            group == 0 || $0.offset / 8 + 1 == group
        }
        .map(\.element)
        let mounts = groupedMounts.filter { mount in
            environment["PATHEM_TRANSIENT_SURFACES_ONLY"].map { $0 == mount.id } ?? true
        }
        let one = environment["PATHEM_TRANSIENT_SURFACES_PROBE_ONE"] == "1"
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
                for mount in (one ? Array(mounts.prefix(1)) : mounts) {
                    for long in mount.filename ? [false, true] : [false] {
                        let name =
                            long ? String(repeating: "n", count: 251) + ".png" : "fixture.png"
                        let cell =
                            "M-\(mount.id)-\(language)-\(appearance == .aqua ? "light" : "dark")-\(Int(size.width))-\(long ? "long255" : "short")"
                        runMount(mount, cell: cell, name: name)
                    }
                }
            }
        }
        NSApp.appearance = nil
    }

    func runMount(_ mount: Mount, cell: String, name: String) {
        mount.reset()
        for cycle in 0..<3 {
            let directory = root.appendingPathComponent(cell + "-\(cycle)", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            let file = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)!
                memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh)
                try rep.representation(using: .png, properties: [:])!.write(to: file)
                try Data("Owned text fixture".utf8).write(
                    to: directory.appendingPathComponent("other.txt"))
            } catch {
                emit(cell, 0, false, "owned image creation failed")
                return
            }
            guard let pane = browser.leftTabs.activePane else {
                emit(cell, 0, false, "missing pane")
                return
            }
            browser.activeSide = browser.leftTabs
            browser.activePane = pane
            pane.navigate(to: directory)
            guard
                settle({
                    pane.currentURL.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath()
                        && pane.debugHasEntry(name)
                })
            else {
                emit(cell, 0, false, "owned listing not delivered")
                return
            }
            pane.debugSelectNames([name])
            guard
                pane.selectedLocalURLs().map({ $0.resolvingSymlinksInPath() }) == [
                    file.resolvingSymlinksInPath()
                ]
            else {
                emit(cell, 0, false, "owned selection not delivered")
                return
            }
            host.makeKeyAndOrderFront(nil)
            host.makeFirstResponder(focus)
            let responder = host.firstResponder.map(ObjectIdentifier.init)
            mount.prepare(file, name)
            let files = snapshot(directory)
            let config = ConfigStore.directory().map(snapshot) ?? [:]
            let before = windows()
            TransientPresentationProbe.current = nil
            let owner = mount.show(file, name)
            let mounted = settle {
                NSApp.windows.contains { $0.isVisible && !before.contains($0.windowNumber) }
            }
            guard mounted,
                let window = NSApp.windows.first(where: {
                    $0.isVisible && !before.contains($0.windowNumber)
                }), let content = window.contentView
            else {
                emit(cell, 4, false, "real presentation not delivered site=\(mount.site)")
                withExtendedLifetime(owner) {}
                return
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let keyReady = settle {
                guard let alert = TransientPresentationProbe.current, alert.window === window else {
                    return window.isVisible
                }
                return alert.buttons.contains {
                    $0.cell === window.defaultButtonCell || $0.keyEquivalent == "\r"
                }
            }
            content.layoutSubtreeIfNeeded()
            emit(cell, 0, true, "cycle=\(cycle) site=\(mount.site)")
            inspect(
                content,
                alert: TransientPresentationProbe.current.flatMap {
                    $0.window === window ? $0 : nil
                }, cell: cell, phase: "cycle\(cycle)-mounted", sheet: window.sheetParent != nil,
                presented: true)
            emit(
                cell, 4,
                (window.sheetParent == nil || window.sheetParent === host)
                    && TransientSurfaceChecks.appearance(content, expected: requestedAppearance),
                "cycle=\(cycle) actual window=\(window.windowNumber) sheet=\(window.sheetParent != nil)",
                content: content)
            let buttons = TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }.filter
            { !$0.isHidden }
            let defaults = buttons.filter {
                $0.keyEquivalent == "\r" || $0.cell === window.defaultButtonCell
            }
            let actualAlert = TransientPresentationProbe.current.flatMap {
                $0.window === window ? $0 : nil
            }
            let expectedDefault = actualAlert?.buttons.first ?? defaults.first
            let binding = TransientReturnBindingProbe.observe(window: window, buttons: buttons) {
                self.key("\r", window: window)
            }
            let bindingOK =
                (!["m08", "m09", "m13", "m55"].contains(mount.id)
                    || policy[mount.site]?["default_destructive_intended"] as? Bool == true)
                && keyReady && binding.resolved && defaults.count <= 1
                && (expectedDefault.map { expected in
                    expected.isEnabled
                        ? (binding.accepted && binding.received.count == 1
                            && binding.received.first === expected)
                        : binding.received.isEmpty
                } ?? binding.received.isEmpty)
            emit(
                cell, 6, bindingOK,
                "cycle=\(cycle) keyReady=\(keyReady) defaults=\(defaults.map(\.title)) accepted=\(binding.accepted) received=\(binding.received.map(\.title)) resolved=\(binding.resolved) productionCallbackWithheld=true",
                content: content)
            if cycle == 0 { capture(content, key: cell + "-initial") }
            let cancel = buttons.first {
                $0.keyEquivalent == "\u{1b}" || $0.title == L("common.cancel", "Cancel")
                    || $0.title == L("common.close", "Close")
            }
            if let cancel {
                cancel.performClick(nil)
            } else if window.styleMask.contains(.closable) {
                window.performClose(nil)
            } else if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)
            {
                // Borderless command bars cancel through their real field-editor
                // responder path, not a close button they do not have.
                window.sendEvent(event)
            }
            let dismissed = settle { !window.isVisible && host.attachedSheet !== window }
            emit(
                cell, 5,
                snapshot(directory) == files
                    && (ConfigStore.directory().map(snapshot) ?? [:]) == config,
                "cycle=\(cycle) Cancel preserves owned files and private configuration",
                content: content)
            emit(
                cell, 7, dismissed && (host.firstResponder.map(ObjectIdentifier.init) == responder),
                "cycle=\(cycle) visible=\(window.isVisible) responderRestored=\(host.firstResponder.map(ObjectIdentifier.init) == responder)",
                content: content)
            emit(
                cell, 8, TransientSurfaceChecks.noAccumulation(before: before, after: windows()),
                "cycle=\(cycle) before=\(before) after=\(windows())", content: content)
            // Only after red receipts, retire the exact fixture-owned window so later
            // cells cannot inherit the failure. This does not turn a red green.
            if !dismissed {
                if window.sheetParent === host { host.endSheet(window) }
                window.orderOut(nil)
            }
            withExtendedLifetime(owner) {}
        }
        print("TSAMPLE: COVERED class=A site=\(mount.site) cell=\(cell)")
    }
}
#endif
