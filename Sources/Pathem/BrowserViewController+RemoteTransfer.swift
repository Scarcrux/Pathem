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
            var destinations = RemoteDownloadDestination(in: dir)
            let items = entries.compactMap { entry -> TransferQueueController.Item? in
                let remotePath = PaneController.joinRemote(ctx.path, entry.name)
                // A server-supplied listing name is untrusted: reduce it to a bare filename so a
                // hostile FTP/SFTP/WebDAV server can't smuggle "../" and write outside the chosen
                // folder. Skip a name that has no safe last component (e.g. "..").
                guard let local = destinations.reserve(for: entry.name) else { return nil }
                return TransferQueueController.Item(
                    name: local.lastPathComponent, totalBytes: entry.size, progressFile: local
                ) {
                    try await provider.download(
                        ctx.connection, remotePath: remotePath, to: local, password: ctx.password)
                }
            }
            guard !self.fileOperationBusy else {
                self.activePane?.flashStatus(
                    L("flash.transferBusy", "A transfer is already running"), isError: true)
                return  // one transfer at a time
            }
            self.transferInFlight = true  // so Quit warns mid-transfer
            self.transferController.run(
                items,
                title: String(
                    format: L("bvc.downloadingFrom", "Downloading from %@"), ctx.connection.host),
                over: window
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
                L(
                    "upload.foldersUnsupportedBody",
                    "Uploading whole folders to a remote server isn’t supported yet. Select individual files to upload them."
                ))
            return
        }
        if files.count < urls.count {
            // A mixed drop: the folders were dropped silently. Say so, but still upload the files.
            presentInfo(
                L("upload.foldersSkippedTitle", "Folders skipped"),
                L(
                    "upload.foldersSkippedBody",
                    "Folder upload isn’t supported yet, so only the files in this drop will be uploaded."
                ))
        }
        let provider = RemoteProviders.make(for: connection.proto)
        let items = files.map { url -> TransferQueueController.Item in
            let dest = PaneController.joinRemote(remotePath, url.lastPathComponent)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            // No local target to poll for an upload, so progressFile is nil (indeterminate bar);
            // totalBytes is still carried for the queue's summary.
            return TransferQueueController.Item(
                name: url.lastPathComponent, totalBytes: size, progressFile: nil
            ) {
                try await provider.upload(url, to: connection, remotePath: dest, password: password)
            }
        }
        guard !fileOperationBusy else {
            activePane?.flashStatus(
                L("flash.transferBusy", "A transfer is already running"), isError: true)
            return  // one transfer at a time
        }
        transferInFlight = true  // so Quit warns mid-transfer
        transferController.run(
            items, title: String(format: L("bvc.uploadingTo", "Uploading to %@"), connection.host),
            over: window
        ) { [weak self, weak pane] failures, cancelled in
            self?.transferInFlight = false
            pane?.refreshRemote()  // show the newly uploaded files
            self?.reportTransfer(failures, cancelled: cancelled, verb: "upload")
        }
    }

    private static let sessionScratch: SessionScratch = {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        var base = temporary
        if PathemApp.isAutomationLaunch,
            let path = ProcessInfo.processInfo.environment["PATHEM_CONFIG_DIR"]
        {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            if candidate.pathComponents.count > temporary.pathComponents.count,
                candidate.pathComponents.starts(with: temporary.pathComponents)
            {
                base = candidate
            }
        }
        return SessionScratch(base: base)
    }()

    /// Each process owns a namespace. Never clean another process's editable downloads.
    private static var remoteTempDir: URL {
        sessionScratch.remote
    }
    private static var archiveTempDir: URL {
        sessionScratch.archives
    }

    /// Idempotent across windows. Previous and legacy namespaces are intentionally retained.
    static func prepareRemoteTemp() {
        do { try sessionScratch.prepare() } catch {
            NSLog(
                "Pathem: could not prepare this session's remote working directory: %@",
                error.localizedDescription)
        }
    }

    #if DEBUG
    static var debugRemoteScratchRoot: URL { sessionScratch.remote }
    #endif

    /// Extract an archive to a fresh temp folder and browse it as a folder.
    func browseArchive(_ archive: URL, in pane: PaneController, origin: URL) {
        let request = pane.beginContentRequest()
        Task { @MainActor [weak self, weak pane] in
            let scratch = Self.archiveTempDir.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            let mount = scratch.appendingPathComponent(
                (archive.lastPathComponent as NSString).deletingPathExtension)
            var mounted = false
            defer {
                if !mounted { try? FileManager.default.removeItem(at: scratch) }
            }
            do {
                try await Archiver.extract(archive, to: mount)
                guard let pane, pane.isContentRequestCurrent(request), pane.currentURL == origin
                else {
                    return
                }
                pane.mountArchive(archive: archive, mountRoot: mount, origin: origin)
                mounted = true
            } catch {
                guard let pane, pane.isContentRequestCurrent(request), pane.currentURL == origin
                else {
                    return
                }
                self?.reportArchiveError(L("archive.cantRead", "Couldn’t read the archive"), error)
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
        // The name comes from a server listing: reduce it to a safe last component so it can't
        // escape the temp dir (the file is then handed to NSWorkspace.open).
        guard let safeName = RemoteDownloadDestination.safeLocalName(name) else {
            NSSound.beep()
            return
        }
        let local = uniqueLocalURL(dir.appendingPathComponent(safeName))
        let provider = RemoteProviders.make(for: connection.proto)
        let item = TransferQueueController.Item(name: name) {
            try await provider.download(
                connection, remotePath: remotePath, to: local, password: password)
        }
        guard !fileOperationBusy else {
            activePane?.flashStatus(
                L("flash.transferBusy", "A transfer is already running"), isError: true)
            return  // one transfer at a time
        }
        transferInFlight = true  // so Quit warns mid-transfer
        transferController.run(
            [item], title: String(format: L("bvc.opening", "Opening %@"), name), over: window
        ) { [weak self] failures, cancelled in
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
        RemoteDownloadDestination.uniqueLocalURL(url)
    }

    func reportTransfer(_ failures: [(String, Error)], cancelled: Bool, verb: String) {
        guard !failures.isEmpty, let window = view.window else { return }  // success/cancel is silent
        let alert = NSAlert()
        alert.messageText =
            failures.count == 1 ? "A \(verb) failed" : "\(failures.count) \(verb)s failed"
        alert.informativeText = failures.prefix(8)
            .map { "\($0.0): \(Self.describeRemote($0.1))" }
            .joined(separator: "\n")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private static func describeRemote(_ error: Error) -> String {
        guard let error = error as? RemoteError else { return error.localizedDescription }
        switch error {
        case .unsupported(let message): return message
        case .curl(let code, let message):
            return message.isEmpty
                ? String(
                    format: L("bvc.connectionFailedCode", "The connection failed (code %d)"), code)
                : message
        case .curlMissing: return L("bvc.curlMissing", "curl was not found")
        case .sftp(let code, let message):
            return message.isEmpty
                ? String(
                    format: L("bvc.connectionFailedCode", "The connection failed (code %d)"), code)
                : message
        case .sftpMissing: return L("bvc.sftpMissing", "sftp was not found")
        case .device(let code, let message):
            return message.isEmpty
                ? String(
                    format: L("bvc.deviceFailedCode", "The device connection failed (code %d)"),
                    code) : message
        case .deviceToolMissing(let tool):
            return String(
                format: L(
                    "bvc.deviceToolMissing",
                    "%@ is not installed. Install it to browse this device."), tool)
        }
    }
}
