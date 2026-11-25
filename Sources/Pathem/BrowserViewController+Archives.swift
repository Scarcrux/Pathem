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
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueLocalURL(folder.appendingPathComponent("\(base).zip"))
        Task { @MainActor [weak self, weak pane] in
            do {
                try await Archiver.compress(urls, to: dest)
                Self.recordActivity(
                    "archive", sources: urls, destination: dest, completed: urls.count)
                if let pane, !pane.isRemote, !pane.isShowingSmartResults,
                    pane.currentURL.path == folder.path
                {
                    pane.selectWhenListed(dest.lastPathComponent) { [weak pane] in
                        pane?.select(name: dest.lastPathComponent)
                    }
                }
                self?.reloadBothSides()
            } catch {
                Self.recordArchiveFailure(sources: urls, destination: dest, error: error)
                self?.reportArchiveError(
                    L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    func compress7zSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueLocalURL(folder.appendingPathComponent("\(base).7z"))
        Task { @MainActor [weak self, weak pane] in
            do {
                try await Archiver.compress7z(urls, to: dest)
                Self.recordActivity(
                    "archive", sources: urls, destination: dest, completed: urls.count)
                if let pane, !pane.isRemote, !pane.isShowingSmartResults,
                    pane.currentURL.path == folder.path
                {
                    pane.selectWhenListed(dest.lastPathComponent) { [weak pane] in
                        pane?.select(name: dest.lastPathComponent)
                    }
                }
                self?.reloadBothSides()
            } catch {
                Self.recordArchiveFailure(sources: urls, destination: dest, error: error)
                self?.reportArchiveError(
                    L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    /// Extract each selected archive into its own folder in the current directory.
    func extractSelection() {
        guard let pane = activePane, !pane.isRemote else {
            NSSound.beep()
            return
        }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            for archive in archives {
                let name = (archive.lastPathComponent as NSString).deletingPathExtension
                let out = self.uniqueLocalURL(folder.appendingPathComponent(name))
                do {
                    try await Archiver.extract(archive, to: out)
                    Self.recordActivity(
                        "archive", sources: [archive], destination: out, completed: 1)
                } catch {
                    failed = true
                    Self.recordArchiveFailure(sources: [archive], destination: out, error: error)
                }
            }
            self.reloadBothSides()
            if failed {
                self.reportArchiveError(
                    L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil)
            }
        }
    }

    /// Extract each selected archive's contents directly into the current directory
    /// (no per-archive subfolder), matching a manager's "Extract Here".
    func extractHereSelection() {
        guard let pane = activePane, !pane.isRemote else {
            NSSound.beep()
            return
        }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            for archive in archives {
                do {
                    try await Archiver.extract(archive, to: folder)
                    Self.recordActivity(
                        "archive", sources: [archive], destination: folder, completed: 1)
                } catch {
                    failed = true
                    Self.recordArchiveFailure(sources: [archive], destination: folder, error: error)
                }
            }
            self.reloadBothSides()
            if failed {
                self.reportArchiveError(
                    L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil)
            }
        }
    }

    /// Choose a destination folder, then extract each selected archive into its own
    /// subfolder there ("Extract to Folder…").
    func extractToSelection() {
        guard let pane = activePane, !pane.isRemote else {
            NSSound.beep()
            return
        }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
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
                    do {
                        try await Archiver.extract(archive, to: out)
                        Self.recordActivity(
                            "archive", sources: [archive], destination: out, completed: 1)
                    } catch {
                        failed = true
                        Self.recordArchiveFailure(
                            sources: [archive], destination: out, error: error)
                    }
                }
                self.reloadBothSides()
                if failed {
                    self.reportArchiveError(
                        L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil)
                }
            }
        }
    }

    /// Peek inside an archive (read-only listing), with Extract All from the panel.
    func peekArchive() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let window = view.window
        else {
            NSSound.beep()
            return
        }
        guard let archive = pane.selectedLocalURLs().first, Archiver.canExtract(archive) else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        Task { @MainActor [self] in
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
        Task { @MainActor [self] in
            let changed = await Task.detached { Archiver.snapshot(of: mountRoot) != original }.value
            guard changed, let window = self.view.window else { return }
            let alert = Self.makeArchiveSaveDialog(archive: archive)
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    self.repackArchive(archive, from: mountRoot)
                case .alertSecondButtonReturn:
                    // Cancel writes nothing and loses nothing: the edited copy stays parked
                    // with its original snapshot; reopening this archive resumes it, and
                    // leaving it again asks again.
                    self.parkArchiveSession(archive, mountRoot: mountRoot, original: original)
                default: break  // Discard: the archive keeps its original contents
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
                Self.recordActivity("archive", sources: [archive], destination: out, completed: 1)
                self.reloadBothSides()
            } catch {
                Self.recordArchiveFailure(sources: [archive], destination: out, error: error)
                self.reportArchiveError(
                    L("bvc.couldntExtract", "Couldn’t extract one or more archives"), error)
            }
        }
    }

    private static func recordArchiveFailure(sources: [URL], destination: URL, error: Error) {
        let systemError = error as NSError
        recordActivity(
            "archive", sources: sources, destination: destination, completed: 0,
            failures: [.init(name: "", reason: "\(systemError.domain) (\(systemError.code))")])
    }

    func reportArchiveError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        if let error { alert.informativeText = error.localizedDescription }  // not the raw Swift dump
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            NSSound.beep()
        }
    }
}

@MainActor
extension BrowserViewController {
    /// Production construction shared with isolated transient checks.
    static func makeArchiveSaveDialog(archive: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(
            format: L("archive.saveBackTitle", "Save changes to %@?"), archive.lastPathComponent
        )
        alert.informativeText = L(
            "archive.saveBackBody",
            "You changed files inside this archive. Repack them into it?")
        alert.addButton(withTitle: L("archive.saveBackSave", "Save to Archive"))
        // Cancel sits next to the default, as in the standard save prompt, and owns Escape
        // explicitly rather than relying on NSAlert recognizing a localized title.
        alert.addButton(withTitle: L("common.cancel", "Cancel")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L("archive.saveBackDiscard", "Discard"))
        return alert
    }

    /// Edited archive copies the user kept with Cancel on the save-back prompt, keyed by the
    /// archive. Each holds the snapshot taken when the archive was first extracted, so the
    /// edits still count as changes when the user comes back and leaves again.
    private struct ParkedArchive {
        let mountRoot: URL
        let snapshot: [String: String]
        let archiveModified: Date?
    }
    private static var parkedArchives: [URL: ParkedArchive] = [:]

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    func parkArchiveSession(_ archive: URL, mountRoot: URL, original: [String: String]) {
        Self.parkedArchives[archive.standardizedFileURL] = ParkedArchive(
            mountRoot: mountRoot, snapshot: original,
            archiveModified: Self.modificationDate(of: archive))
    }

    /// Open an archive as a folder. If the user cancelled the save-back prompt for it, resume
    /// that edited copy instead of extracting a fresh one, unless the archive changed on disk
    /// since (then the parked copy is stale and repacking it would overwrite newer contents).
    func openArchive(_ archive: URL, in pane: PaneController, origin: URL) {
        if let parked = Self.parkedArchives.removeValue(forKey: archive.standardizedFileURL),
            FileManager.default.fileExists(atPath: parked.mountRoot.path),
            parked.archiveModified == Self.modificationDate(of: archive)
        {
            pane.mountArchive(
                archive: archive, mountRoot: parked.mountRoot, origin: origin,
                prior: parked.snapshot)
            return
        }
        browseArchive(archive, in: pane, origin: origin)
    }

    func repackArchive(_ archive: URL, from mountRoot: URL) {
        Task { @MainActor in
            do {
                try await Archiver.repack(from: mountRoot, into: archive)
                Self.recordActivity(
                    "archive", sources: [mountRoot], destination: archive, completed: 1)
                self.reloadBothSides()
            } catch {
                Self.recordArchiveFailure(sources: [mountRoot], destination: archive, error: error)
                self.reportArchiveError(
                    L("archive.saveBackFailed", "Couldn’t save changes to the archive"), error)
            }
        }
    }
}
