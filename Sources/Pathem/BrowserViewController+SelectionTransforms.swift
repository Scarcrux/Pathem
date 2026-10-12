import AppKit
import PathemEngine
import Quartz

// Commands that transform, relocate, or destroy the active selection on disk: build a
// combined PDF, split/merge file parts, offload iCloud files, back up to a chosen folder,
// git-aware repo reclaim, create an encrypted disk image, secure-delete, make symlink/
// alias/hardlink, mount/attach a disk image, and eject a volume. Split out of
// BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Build a single PDF from images (one page each) and PDFs (all their pages), in selection
    /// order, written to a uniquely-named file in `folder`. Returns the URL, or nil on failure.
    nonisolated static func buildPDF(from urls: [URL], in folder: URL) -> URL? {
        let document = PDFDocument()
        var pageIndex = 0
        for url in urls {
            if url.pathExtension.lowercased() == "pdf", let source = PDFDocument(url: url) {
                for i in 0..<source.pageCount where source.page(at: i) != nil {
                    document.insert(source.page(at: i)!, at: pageIndex)
                    pageIndex += 1
                }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                document.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }
        guard document.pageCount > 0 else { return nil }
        let fm = FileManager.default
        var out = folder.appendingPathComponent("Combined.pdf")
        var n = 2
        while fm.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("Combined \(n).pdf")
            n += 1
        }
        return document.write(to: out) ? out : nil
    }

    /// Split the selected file into fixed-size parts (asks for a size in MB), off-main.
    func splitSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first,
            !entry.isDirectory
        else {
            NSSound.beep()
            return
        }
        let file = pane.currentURL.appendingPathComponent(entry.name)
        Task { @MainActor in
            guard
                let input = await self.promptForName(
                    title: L("bvc.splitTitle", "Split into parts of how many MB?"), default: "100"),
                let mb = Double(input.trimmingCharacters(in: .whitespaces)), mb > 0
            else { return }
            let partSize = Int64(mb * 1_000_000)
            do {
                _ = try await Task.detached { try FileSplitter.split(file, partSize: partSize) }
                    .value
                self.activePane?.reloadIfShowingListing()
            } catch {
                self.presentInfo(
                    L("bvc.splitFailed", "Couldn’t split the file"), error.localizedDescription)
            }
        }
    }

    /// Merge the ".001/.002/…" parts starting at the selected part back into the whole.
    func mergeSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let entry = pane.selectedEntries.first
        else {
            NSSound.beep()
            return
        }
        let part = pane.currentURL.appendingPathComponent(entry.name)
        Task { @MainActor in
            do {
                let merged = try await Task.detached { try FileSplitter.merge(firstPart: part) }
                    .value
                self.activePane?.reloadIfShowingListing()
                self.activePane?.select(name: merged.lastPathComponent)
            } catch {
                self.presentInfo(
                    L("bvc.mergeFailed", "Couldn’t merge the parts"), error.localizedDescription)
            }
        }
    }

    /// Offload the selected downloaded iCloud files (evict the local copy; the cloud copy
    /// stays and the file becomes online-only).
    func offloadSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs().filter { Backup.isOffloadable($0) }
        guard !urls.isEmpty else {
            presentInfo(
                L("offload.none", "Nothing to offload"),
                L("offload.noneBody", "Select downloaded iCloud files to free their local space."))
            return
        }
        let result = Backup.offload(urls)
        pane.reloadIfShowingListing()
        if !result.failures.isEmpty {
            presentFailures(result.failures, title: L("offload.failed", "Couldn’t offload"))
        }
    }

    /// Copy the selection to a chosen destination as a backup (originals kept).
    func backupSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        backup(urls, over: window)
    }

    /// Inside a git repository, split the current folder's contents into what git already
    /// protects (tracked), what's safe to reclaim (regenerable build output/caches), and what
    /// git ISN'T protecting and is worth backing up (precious untracked data). Then offer to
    /// clean the first and back up the second.
    func repoReclaim() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        guard let window = view.window else { return }
        Task { @MainActor [self] in
            let items = await RepoScan.classify(folder)
            guard !items.isEmpty else {
                self.presentInfo(
                    L("repo.notRepo", "Not a git repository"),
                    L(
                        "repo.notRepoBody",
                        "Reclaim only runs inside a git repository, where it can tell tracked files from regenerable junk and precious untracked data."
                    ))
                return
            }
            let regenerable = items.filter { $0.disposition == .regenerable }
            let precious = items.filter { $0.disposition == .precious }
            let tracked = items.filter { $0.disposition == .tracked }
            let bytes = ByteCountFormatter()
            func size(_ list: [RepoScan.Item]) -> String {
                bytes.string(fromByteCount: list.reduce(0) { $0 + $1.size })
            }
            func urls(_ list: [RepoScan.Item]) -> [URL] {
                list.map { folder.appendingPathComponent($0.name) }
            }

            let alert = NSAlert()
            alert.messageText = String(
                format: L("repo.title", "Reclaim in %@"), folder.lastPathComponent)
            alert.informativeText = String(
                format: L(
                    "repo.summary",
                    "Regenerable (safe to clean): %d, %@\nPrecious (untracked, worth backing up): %d, %@\nTracked (git already has these): %d"
                ),
                regenerable.count, size(regenerable), precious.count, size(precious), tracked.count)

            // Offer only the actions that apply, mapped by button order.
            var actions: [() -> Void] = []
            if !regenerable.isEmpty {
                alert.addButton(
                    withTitle: String(
                        format: L("repo.clean", "Clean Regenerable (%d)"), regenerable.count))
                let toTrash = urls(regenerable)
                actions.append { [weak self] in self?.performLocalTrash(toTrash) }
            }
            if !precious.isEmpty {
                alert.addButton(
                    withTitle: String(
                        format: L("repo.backup", "Back Up Precious… (%d)"), precious.count))
                let toBackUp = urls(precious)
                actions.append { [weak self] in self?.backup(toBackUp, over: window) }
            }
            if actions.isEmpty {
                self.presentInfo(
                    L("repo.nothing", "Nothing to reclaim"),
                    L(
                        "repo.nothingBody",
                        "Everything here is tracked by git. There's no regenerable junk to clean and no untracked data to back up."
                    ))
                return
            }
            alert.addButton(withTitle: L("common.close", "Close"))
            alert.beginSheetModal(for: window) { response in
                let index =
                    response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if index >= 0 && index < actions.count { actions[index]() }
            }
        }
    }

    /// Copy the given files to a chosen destination as a backup (originals kept). Shared by
    /// the selection backup and the repo-reclaim precious-data backup.
    private func backup(_ urls: [URL], over window: NSWindow) {
        guard !urls.isEmpty else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.prompt = L("backup.choose", "Back Up Here")
        picker.message = L("backup.message", "Choose a destination for the backup copy")
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url, let self else { return }
            Task { @MainActor in
                let result = await Task.detached { Backup.backup(urls, to: destination) }.value
                if !result.failures.isEmpty {
                    self.presentFailures(
                        result.failures, title: L("backup.failed", "Couldn’t back up"))
                } else {
                    self.presentInfo(
                        L("backup.done", "Backed up"),
                        String(
                            format: L("backup.doneBody", "Copied %d item(s) to %@."),
                            result.succeeded.count, destination.lastPathComponent))
                }
            }
        }
    }

    /// Create an AES-256 encrypted disk image containing the selection, after prompting for
    /// a volume name and password.
    func encryptToDiskImage() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        nameField.stringValue =
            urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Encrypted"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        passField.placeholderString = L("dmg.password", "Password")
        func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
            let name = NSTextField(labelWithString: label)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let row = NSStackView(views: [name, control])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        let accessory = NSStackView(views: [
            labeledRow(L("dmg.name", "Name"), nameField),
            labeledRow(L("dmg.passwordLabel", "Password"), passField),
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 66)

        let alert = NSAlert()
        alert.messageText = String(
            format: L("dmg.title", "New Encrypted Disk Image (%d item(s))"), urls.count)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("dmg.create", "Create"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.isEmpty ? "Encrypted" : nameField.stringValue
            let password = passField.stringValue
            guard !password.isEmpty else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                do {
                    let dmg = try await Task.detached {
                        try await DiskImage.createEncrypted(
                            from: urls, volumeName: name, password: password, in: folder)
                    }.value
                    self.activePane?.reloadIfShowingListing()
                    self.activePane?.select(name: dmg.lastPathComponent)
                } catch {
                    self.presentInfo(
                        L("dmg.failed", "Couldn’t create the disk image"),
                        error.localizedDescription)
                }
            }
        }
    }

    /// Overwrite the selected files with random data and delete them, after a strong
    /// confirmation. Irreversible, and there is no Trash.
    func secureDeleteSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            format: L("bvc.secureDeleteQ", "Securely erase %d item(s)?"), urls.count)
        alert.informativeText = L(
            "bvc.secureDeleteBody",
            "The files are overwritten with random data and deleted. This cannot be undone and does not use the Trash. On SSD or APFS storage, secure erasure is best-effort."
        )
        alert.addButton(withTitle: L("bvc.secureDeleteConfirm", "Erase"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let result = await Task.detached { SecureDelete.shred(urls) }.value
                self.activePane?.reloadIfShowingListing()
                if !result.failures.isEmpty {
                    self.presentFailures(
                        result.failures, title: L("bvc.secureDeleteFailed", "Couldn’t erase"))
                }
            }
        }
    }

    /// Create a symlink, alias, or hard link next to each selected item (undoable).
    func makeLinks(kind: FileOperations.LinkKind) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let outcome = FileOperations.makeLinks(urls, kind: kind)
        let createdNames = outcome.performed.map { $0.destination.lastPathComponent }
        if let first = createdNames.first {
            // The created row is not in the off-main listing yet. Select and reveal only
            // after it lands, rather than silently leaving the source selected.
            pane.selectWhenListed(first) { [weak pane] in pane?.select(name: first) }
        }
        pane.reloadIfShowingListing()
        if !createdNames.isEmpty {
            registerCreatedUndo(
                names: createdNames, in: pane.currentURL,
                actionName: L("bvc.makeLinkAction", "Make Link"))
        }
        if !outcome.failures.isEmpty {
            presentFailures(
                outcome.failures, title: L("bvc.makeLinkFailed", "Couldn’t create the link"))
        }
    }

    /// Attach a disk image (.dmg etc.) out-of-process and navigate the pane into it.
    func attachDiskImage(_ image: URL, in pane: PaneController?) {
        Task { @MainActor [weak self] in
            do {
                let mountPoint = try await DiskImage.attach(image)
                (pane ?? self?.activePane)?.navigate(to: mountPoint)
            } catch {
                self?.reportArchiveError(
                    L("bvc.couldntMount", "Couldn’t mount the disk image"), error)
            }
        }
    }

    /// Eject the volume that contains the active folder (disk image, USB, network share).
    func ejectActiveVolume() {
        guard let pane = activePane, !pane.isRemote,
            let volume = (try? pane.currentURL.resourceValues(forKeys: [.volumeURLKey]))?.volume
        else {
            NSSound.beep()
            return
        }
        ejectVolume(volume)
    }

    /// Eject a specific mounted volume, moving any pane that was inside it back home.
    func ejectVolume(_ volume: URL) {
        // Hard backstop, independent of any volume flag: never eject the boot volume or a system
        // volume (a firmlinked /System/Volumes/* mount could otherwise slip through a flag check).
        let path = volume.standardizedFileURL.path
        if path == "/" || path.hasPrefix("/System/") {
            NSSound.beep()
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for side in [leftTabs, rightTabs] {
            if let pane = side.activePane, !pane.isRemote,
                pane.currentURL.path.hasPrefix(volume.path)
            {
                pane.navigate(to: home)
            }
        }
        // unmountAndEjectDevice BLOCKS until the unmount finishes -- flushing write buffers and
        // releasing handles can take many seconds, and on the main thread that beachballs the whole
        // app (the ~15s "struggle" report). Run it off the main thread and flash a status while it
        // works, then confirm or report on the main thread.
        let name = FileManager.default.displayName(atPath: volume.path)
        activePane?.flashStatus(String(format: L("bvc.ejecting", "Ejecting %@…"), name))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.activePane?.flashStatus(
                        String(format: L("bvc.ejected", "Ejected %@"), name))
                case .failure(let error):
                    self?.reportArchiveError(
                        L("bvc.couldntEject", "Couldn’t eject the volume"), error)
                }
            }
        }
    }
}
