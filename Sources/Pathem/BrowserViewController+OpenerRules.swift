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
        guard let pane = activePane, let entry = pane.selectedEntries.first, !entry.isDirectory else {
            NSSound.beep()
            return
        }
        let fileURL = entry.location.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.name) }
            ?? pane.currentURL.appendingPathComponent(entry.name)  // location-aware
        let ext = fileURL.pathExtension.lowercased()

        let alert = NSAlert()
        alert.messageText = L("bvc.alwaysOpenWith", "Always Open With")
        alert.informativeText = L("bvc.alwaysOpenWithBody", "Choose an application and how widely to apply it.")

        // App picker: candidate apps + Choose…
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let appPopup = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 320, height: 26))
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
            item.representedObject = app
            appPopup.menu?.addItem(item)
        }
        if !apps.isEmpty { appPopup.menu?.addItem(.separator()) }
        appPopup.addItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))

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
        alert.addButton(withTitle: L("bvc.set", "Set"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.resolveChosenApp(appPopup, candidates: apps, over: window) { appURL in
                guard let appURL else { return }
                let scope = OpenerScope(rawValue: scopePopup.indexOfSelectedItem) ?? .file
                self.saveOpener(appPath: appURL.path, for: fileURL, ext: ext, scope: scope)
            }
        }
    }

    /// Resolve the app chosen in the popup; "Choose…" opens an app picker.
    private func resolveChosenApp(
        _ popup: NSPopUpButton, candidates: [URL], over window: NSWindow,
        completion: @escaping (URL?) -> Void
    ) {
        if let app = popup.selectedItem?.representedObject as? URL {
            completion(app)
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
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
            let type = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: ext) ?? .data
            NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: appPath), toOpen: type) { _ in }
            openerRules.clearType(ext)
        case .session: sessionOpenersByType[ext] = appPath
        }
        if scope != .session { saveConfig(openerRules, to: Self.openersURL) }
    }
}
