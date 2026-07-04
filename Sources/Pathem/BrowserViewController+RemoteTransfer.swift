import AppKit
import PathemEngine

// Remote file transfer: download/upload between a remote pane and the local disk,
// browsing an archive, opening a remote file, and the transfer-queue reporting.
// Split out of BrowserViewController.
extension BrowserViewController {
    // MARK: - Remote file transfer

    /// Download the selected remote files (in the active remote pane) to a folder.
    func downloadSelectedRemote() {
        guard let pane = activePane, let ctx = pane.remoteContext, let window = view.window else {
            NSSound.beep()
            return
        }
        let entries = pane.selectedEntries.filter { !$0.isDirectory }  // folder download is a later step
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = L("bvc.downloadHere", "Download Here")
        openPanel.message = String(
            format: L("bvc.chooseDownloadDest", "Choose where to save %d item(s) from %@"),
            entries.count, ctx.connection.host)
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dir = openPanel.url, let self else { return }
            let provider = RemoteProviders.make(for: ctx.connection.proto)
            let items = entries.map { entry -> TransferQueueController.Item in
                let remotePath = PaneController.joinRemote(ctx.path, entry.name)
                let local = self.uniqueLocalURL(dir.appendingPathComponent(entry.name))
                return TransferQueueController.Item(name: entry.name, totalBytes: entry.size, progressFile: local) {
                    try await provider.download(
                        ctx.connection, remotePath: remotePath, to: local, password: ctx.password)
                }
            }
            guard !self.transferInFlight else { NSSound.beep(); return }  // one transfer at a time
            self.transferInFlight = true  // so Quit warns mid-transfer
            self.transferController.run(
                items, title: String(format: L("bvc.downloadingFrom", "Downloading from %@"), ctx.connection.host), over: window
            ) { [weak self] failures, cancelled in
                self?.transferInFlight = false
                self?.reportTransfer(failures, cancelled: cancelled, verb: "download")
            }
        }
    }

    /// Upload local files dropped onto a remote pane to its current folder.
    func uploadFiles(
        _ urls: [URL], to connection: RemoteConnection, remotePath: String, password: String,
        pane: PaneController
    ) {
        guard let window = view.window else { return }
        let files = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
        guard !files.isEmpty else {
            presentInfo(
                L("upload.foldersUnsupportedTitle", "Can’t upload folders yet"),
                L("upload.foldersUnsupportedBody", "Uploading whole folders to a remote server isn’t supported yet. Select individual files to upload them."))
            return
        }
        if files.count < urls.count {
            // A mixed drop: the folders were dropped silently. Say so, but still upload the files.
            presentInfo(
                L("upload.foldersSkippedTitle", "Folders skipped"),
                L("upload.foldersSkippedBody", "Folder upload isn’t supported yet, so only the files in this drop will be uploaded."))
        }
        let provider = RemoteProviders.make(for: connection.proto)
        let items = files.map { url -> TransferQueueController.Item in
            let dest = PaneController.joinRemote(remotePath, url.lastPathComponent)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            // No local target to poll for an upload, so progressFile is nil (indeterminate bar);
            // totalBytes is still carried for the queue's summary.
            return TransferQueueController.Item(name: url.lastPathComponent, totalBytes: size, progressFile: nil) {
                try await provider.upload(url, to: connection, remotePath: dest, password: password)
            }
        }
        guard !transferInFlight else { NSSound.beep(); return }  // one transfer at a time
        transferInFlight = true  // so Quit warns mid-transfer
        transferController.run(
            items, title: String(format: L("bvc.uploadingTo", "Uploading to %@"), connection.host), over: window
        ) { [weak self, weak pane] failures, cancelled in
            self?.transferInFlight = false
            pane?.refreshRemote()  // show the newly uploaded files
            self?.reportTransfer(failures, cancelled: cancelled, verb: "upload")
        }
    }

    /// Temp directory for remote files opened locally.
    private static var remoteTempDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pathem-Remote", isDirectory: true)
    }
    private static var archiveTempDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pathem-Archives", isDirectory: true)
    }

    /// Remove leftover opened-remote files and extracted archives from a previous run.
    /// Done once at launch so it never deletes something in use this session.
    static func cleanupRemoteTemp() {
        try? FileManager.default.removeItem(at: remoteTempDir)
        try? FileManager.default.removeItem(at: archiveTempDir)
    }

    /// Extract an archive to a fresh temp folder and browse it as a folder.
    func browseArchive(_ archive: URL, in pane: PaneController, origin: URL) {
        Task { @MainActor in
            let mount = Self.archiveTempDir.appendingPathComponent(
                UUID().uuidString, isDirectory: true
            ).appendingPathComponent((archive.lastPathComponent as NSString).deletingPathExtension)
            do {
                try await Archiver.extract(archive, to: mount)
                pane.mountArchive(archive: archive, mountRoot: mount, origin: origin)
            } catch {
                self.reportArchiveError(L("archive.cantRead", "Couldn’t read the archive"), error)
            }
        }
    }

    /// Double-clicking a remote file: download it to a temp file and open it.
    func openRemoteFile(
        _ connection: RemoteConnection, remotePath: String, password: String, name: String
    ) {
        guard let window = view.window else { return }
        let dir = Self.remoteTempDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = uniqueLocalURL(dir.appendingPathComponent(name))
        let provider = RemoteProviders.make(for: connection.proto)
        let item = TransferQueueController.Item(name: name) {
            try await provider.download(connection, remotePath: remotePath, to: local, password: password)
        }
        guard !transferInFlight else { NSSound.beep(); return }  // one transfer at a time
        transferInFlight = true  // so Quit warns mid-transfer
        transferController.run([item], title: String(format: L("bvc.opening", "Opening %@"), name), over: window) { [weak self] failures, cancelled in
            self?.transferInFlight = false
            guard !cancelled else { return }
            if failures.isEmpty {
                NSWorkspace.shared.open(local)
            } else {
                self?.reportTransfer(failures, cancelled: false, verb: "download")
            }
        }
    }

    /// Avoid clobbering a local file: append " 2", " 3", … if the name is taken.
    func uniqueLocalURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func reportTransfer(_ failures: [(String, Error)], cancelled: Bool, verb: String) {
        guard !failures.isEmpty, let window = view.window else { return }  // success/cancel is silent
        let alert = NSAlert()
        alert.messageText = failures.count == 1 ? "A \(verb) failed" : "\(failures.count) \(verb)s failed"
        alert.informativeText = failures.prefix(8)
            .map { "\($0.0): \(Self.describeRemote($0.1))" }
            .joined(separator: "\n")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private static func describeRemote(_ error: Error) -> String {
        guard let error = error as? RemoteError else { return error.localizedDescription }
        switch error {
        case .unsupported(let message): return message
        case .curl(let code, let message): return message.isEmpty ? String(format: L("bvc.curlError", "curl error %d"), code) : message
        case .curlMissing: return L("bvc.curlMissing", "curl was not found")
        case .sftp(let code, let message): return message.isEmpty ? String(format: L("bvc.sftpError", "sftp error %d"), code) : message
        case .sftpMissing: return L("bvc.sftpMissing", "sftp was not found")
        case .device(let code, let message): return message.isEmpty ? String(format: L("bvc.deviceError", "device error %d"), code) : message
        case .deviceToolMissing(let tool): return String(format: L("bvc.deviceToolMissing", "%@ is not installed. Install it to browse this device."), tool)
        }
    }
}
