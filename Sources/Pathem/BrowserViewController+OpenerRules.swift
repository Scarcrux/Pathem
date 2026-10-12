import AppKit
import PathemEngine
import UniformTypeIdentifiers

// How Pathem decides which app opens a file: the persisted scoped opener rules (by file /
// folder / type) plus session overrides, and the Get Info "Open with" default picker. Split
// out of BrowserViewController to keep the opener policy in one place.
@MainActor
extension BrowserViewController {
    func loadOpenerRules() {
        guard var saved = loadConfig(OpenerRules.self, from: Self.openersURL) else { return }
        // One-time migration: per-kind defaults now live in the system (LaunchServices), so drop
        // any legacy Pathem per-extension rules -- those kinds then defer to the system default,
        // like Finder. Per-file and per-folder overlays are kept (the OS can't express them).
        if !saved.byType.isEmpty {
            saved.byType.removeAll()
            saveConfig(saved, to: Self.openersURL)
        }
        openerRules = saved
    }

    /// Open a file with its resolved app: session override (by type) first, then
    /// the persisted file/folder/type rules, else the system default.
    func applyOpen(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // A .torrent opens in Pathem's own Torrents panel rather than handing off to another app.
        if ext == "torrent" {
            addTorrentToPanel(url)
            return
        }
        // Precedence: a specific file/folder rule, then a session-by-type override,
        // then a persisted type rule, else the system default.
        let appPath =
            openerRules.appByFileOrFolder(path: url.path) ?? sessionOpenersByType[ext]
            ?? openerRules.app(forType: ext)
        if let appPath {
            NSWorkspace.shared.open(
                [url], withApplicationAt: URL(fileURLWithPath: appPath),
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Scope for "Always Open With".
    private enum OpenerScope: Int { case file, folder, type, session }

    /// Set a default opener for the active selection. Shown from Open With.
    @objc func setDefaultOpener(_ sender: Any?) {
        if blockedByRemote() { return }
        guard let pane = activePane, let entry = pane.selectedEntries.first, !entry.isDirectory
        else {
            NSSound.beep()
            return
        }
        let fileURL =
            entry.location.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.name) }
            ?? pane.currentURL.appendingPathComponent(entry.name)  // location-aware
        let ext = fileURL.pathExtension.lowercased()

        let alert = NSAlert()
        alert.messageText = L("bvc.alwaysOpenWith", "Always Open With")
        alert.informativeText = L(
            "bvc.alwaysOpenWithBody", "Choose an application and how widely to apply it.")
        alert.addButton(withTitle: L("bvc.set", "Set"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        // App picker: candidate apps + Choose…
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let appPopup = DefaultOpenerApplicationPopup(apps: apps, setButton: alert.buttons[0])

        let scopePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        scopePopup.addItem(withTitle: L("bvc.scopeThisFile", "This file"))
        scopePopup.addItem(withTitle: L("bvc.scopeThisFolder", "Files in this folder"))
        scopePopup.addItem(
            withTitle: ext.isEmpty
                ? L("bvc.scopeThisKind", "Files of this kind (system-wide)")
                : String(format: L("bvc.scopeAllExt", "All .%@ files (system-wide)"), ext))
        scopePopup.addItem(withTitle: L("bvc.scopeThisSession", "Just this session"))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        accessory.addSubview(appPopup)
        accessory.addSubview(scopePopup)
        alert.accessoryView = accessory

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                let appURL = appPopup.selectedItem?.representedObject as? URL
            else { return }
            let scope = OpenerScope(rawValue: scopePopup.indexOfSelectedItem) ?? .file
            self.saveOpener(appPath: appURL.path, for: fileURL, ext: ext, scope: scope)
        }
    }

    private func saveOpener(appPath: String, for fileURL: URL, ext: String, scope: OpenerScope) {
        switch scope {
        case .file: openerRules.setFile(fileURL.path, app: appPath)
        case .folder: openerRules.setFolder(fileURL.deletingLastPathComponent().path, app: appPath)
        case .type:
            // "Files of this kind" is Finder's "Change All": set the real system default
            // (LaunchServices) so Pathem, Finder, and every other app agree, and drop any local
            // per-type rule so the system stays authoritative even if the default changes later.
            let type =
                (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: ext) ?? .data
            NSWorkspace.shared.setDefaultApplication(
                at: URL(fileURLWithPath: appPath), toOpen: type
            ) { _ in }
            openerRules.clearType(ext)
        case .session: sessionOpenersByType[ext] = appPath
        }
        if scope != .session { saveConfig(openerRules, to: Self.openersURL) }
    }
}

/// Own the popup action for as long as the alert accessory is mounted. Choosing an
/// app is distinct from committing its scope with Set; picker cancellation is inert.
@MainActor
final class DefaultOpenerApplicationPopup: NSPopUpButton {
    private weak var setButton: NSButton?
    private var previousApplication: URL?
    private var applicationPanel: NSOpenPanel?

    init(apps: [URL], setButton: NSButton) {
        self.setButton = setButton
        super.init(frame: NSRect(x: 0, y: 34, width: 320, height: 26), pullsDown: false)
        for app in apps {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: app.path), action: nil,
                keyEquivalent: "")
            item.representedObject = app
            menu?.addItem(item)
        }
        if !apps.isEmpty { menu?.addItem(.separator()) }
        addItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))
        previousApplication = selectedItem?.representedObject as? URL
        setButton.isEnabled = previousApplication != nil
        target = self
        action = #selector(applicationChanged(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func applicationChanged(_ sender: Any?) {
        guard applicationPanel == nil else { return }
        if let app = selectedItem?.representedObject as? URL {
            previousApplication = app
            setButton?.isEnabled = true
            return
        }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        applicationPanel = panel
        isEnabled = false
        setButton?.isEnabled = false
        // Attach to the alert, not its browser parent: the parent's existing alert
        // would otherwise queue the picker until after Set/Cancel dismissed it.
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.applicationPanel = nil
            self.isEnabled = true
            self.selectApplication(response == .OK ? panel.url : self.previousApplication)
        }
    }

    /// Shared by native picker completion and candidate restoration after Cancel.
    func selectApplication(_ app: URL?) {
        if let app {
            let existing = itemArray.first { ($0.representedObject as? URL) == app }
            let item =
                existing
                ?? NSMenuItem(
                    title: FileManager.default.displayName(atPath: app.path), action: nil,
                    keyEquivalent: "")
            if existing == nil {
                item.representedObject = app
                menu?.insertItem(item, at: 0)
            }
            select(item)
        } else {
            selectItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))
        }
        previousApplication = app
        setButton?.isEnabled = app != nil
    }
}
