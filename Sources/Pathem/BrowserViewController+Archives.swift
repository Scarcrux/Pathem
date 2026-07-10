import AppKit
import PathemEngine

// Archive lifecycle: compress (zip/7z), extract (in place / here / to a chosen folder),
// peek an archive's contents, write back changes made while browsing a mounted archive,
// and the shared archive-error alert. Split out of BrowserViewController.
extension BrowserViewController {
    // MARK: - Archives

    /// Zip the selection into the current folder (off-main), then select the archive.
    func compressSelection() {
        // Smart/flat/duplicate views span multiple folders; Archiver assumes one
        // shared parent, so restrict Compress to a single real folder.
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueLocalURL(folder.appendingPathComponent("\(base).zip"))
        Task { @MainActor [weak self] in
            do {
                try await Archiver.compress(urls, to: dest)
                self?.reloadBothSides()
                self?.activePane?.select(name: dest.lastPathComponent)
            } catch {
                self?.reportArchiveError(L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    func compress7zSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueLocalURL(folder.appendingPathComponent("\(base).7z"))
        Task { @MainActor [weak self] in
            do {
                try await Archiver.compress7z(urls, to: dest)
                self?.reloadBothSides()
                self?.activePane?.select(name: dest.lastPathComponent)
            } catch {
                self?.reportArchiveError(L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    /// Extract each selected archive into its own folder in the current directory.
    func extractSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            for archive in archives {
                let name = (archive.lastPathComponent as NSString).deletingPathExtension
                let out = self.uniqueLocalURL(folder.appendingPathComponent(name))
                do { try await Archiver.extract(archive, to: out) } catch { failed = true }
            }
            self.reloadBothSides()
            if failed { self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil) }
        }
    }

    /// Extract each selected archive's contents directly into the current directory
    /// (no per-archive subfolder), matching a manager's "Extract Here".
    func extractHereSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            for archive in archives {
                do { try await Archiver.extract(archive, to: folder) } catch { failed = true }
            }
            self.reloadBothSides()
            if failed { self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil) }
        }
    }

    /// Choose a destination folder, then extract each selected archive into its own
    /// subfolder there ("Extract to Folder…").
    func extractToSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty, let window = view.window else { NSSound.beep(); return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = L("extract.choose", "Extract Here")
        picker.message = L("extract.message", "Choose a folder to extract into")
        picker.directoryURL = pane.currentURL
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url, let self else { return }
            Task { @MainActor in
                var failed = false
                for archive in archives {
                    let name = (archive.lastPathComponent as NSString).deletingPathExtension
                    let out = self.uniqueLocalURL(destination.appendingPathComponent(name))
                    do { try await Archiver.extract(archive, to: out) } catch { failed = true }
                }
                self.reloadBothSides()
                if failed { self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil) }
            }
        }
    }

    /// Peek inside an archive (read-only listing), with Extract All from the panel.
    func peekArchive() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let window = view.window
        else { NSSound.beep(); return }
        guard let archive = pane.selectedLocalURLs().first, Archiver.canExtract(archive) else {
            NSSound.beep(); return
        }
        let folder = pane.currentURL
        Task { @MainActor in
            do {
                let paths = try await Archiver.list(archive)
                self.archiveContents.present(
                    over: window, archiveName: archive.lastPathComponent, entries: paths,
                    onExtractAll: { [weak self] in self?.extractArchive(archive, in: folder) })
            } catch {
                self.reportArchiveError(L("archive.cantRead", "Couldn’t read the archive"), error)
            }
        }
    }

    /// On leaving a browsed archive, if its extracted contents changed, offer to repack
    /// them back into the original archive.
    func writeBackArchiveIfChanged(archive: URL, mountRoot: URL, original: [String: String]) {
        // RAR and other read-only formats can't be repacked; browse them without prompting.
        guard Archiver.canRepack(archive) else { return }
        Task { @MainActor in
            let changed = await Task.detached { Archiver.snapshot(of: mountRoot) != original }.value
            guard changed, let window = self.view.window else { return }
            let alert = NSAlert()
            alert.messageText = String(
                format: L("archive.saveBackTitle", "Save changes to %@?"), archive.lastPathComponent)
            alert.informativeText = L(
                "archive.saveBackBody", "You changed files inside this archive. Repack them into it?")
            alert.addButton(withTitle: L("archive.saveBackSave", "Save to Archive"))
            alert.addButton(withTitle: L("archive.saveBackDiscard", "Discard"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                Task { @MainActor in
                    do {
                        try await Archiver.repack(from: mountRoot, into: archive)
                        self.reloadBothSides()
                    } catch {
                        self.reportArchiveError(
                            L("archive.saveBackFailed", "Couldn’t save changes to the archive"), error)
                    }
                }
            }
        }
    }

    func extractArchive(_ archive: URL, in folder: URL) {
        Task { @MainActor in
            let name = (archive.lastPathComponent as NSString).deletingPathExtension
            let out = self.uniqueLocalURL(folder.appendingPathComponent(name))
            do {
                try await Archiver.extract(archive, to: out)
                self.reloadBothSides()
            } catch {
                self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), error)
            }
        }
    }

    func reportArchiveError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        if let error { alert.informativeText = "\(error)" }
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } } else { NSSound.beep() }
    }
}
