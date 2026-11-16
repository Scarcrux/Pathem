import AppKit
import PathemEngine
import TorrentKit
import UniformTypeIdentifiers

@MainActor
extension BrowserViewController {
    /// Add every selected .torrent to the Torrents panel.
    func addSelectedTorrents() {
        let urls = selectedTorrentURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        for url in urls { addTorrentToPanel(url) }
    }

    /// Create a .torrent from the selected file or folder: prompt for a tracker + private flag,
    /// choose where to save, then hash off the main thread and reveal the result.
    func createTorrentFromSelection() {
        guard let source = selectedSingleLocalURL else {
            NSSound.beep()
            return
        }

        let (alert, tracker, privateCheck) = Self.makeCreateTorrentDialog(source: source)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trackerText = tracker.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = TorrentCreator.Options(
            trackers: trackerText.isEmpty ? [] : [trackerText],
            isPrivate: privateCheck.state == .on,
            creationDate: Date())

        let (save, suggestion) = Self.makeTorrentSaveDialog(
            source: source, offerSuggestions: prefs.suggestFilenames && AIAssistant.isAvailable)
        defer { suggestion?.cancel() }
        guard save.runModal() == .OK, let dest = save.url else { return }

        // Hashing can be slow for large content, so run it off the main thread.
        Task.detached {
            do {
                let data = try TorrentCreator.create(contentsOf: source, options: options)
                try data.write(to: dest)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
            } catch {
                await MainActor.run {
                    let fail = NSAlert()
                    fail.messageText = L("torrents.create.failed", "Couldn't create the torrent")
                    fail.informativeText = error.localizedDescription
                    fail.runModal()
                }
            }
        }
    }

    /// Copy the magnet links of the selected .torrent files to the clipboard.
    func copySelectedMagnetLinks() {
        let links = selectedTorrentURLs.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url), let torrent = try? TorrentFile.parse(data)
            else { return nil }
            return torrent.magnetLink
        }
        guard !links.isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    /// Open the Torrents drawer and add a .torrent handed in by another app (Finder open / Services).
    /// Optionally confirms first (drive-by-download protection); downloads go to the configured folder.
    func addTorrentToPanel(_ url: URL) {
        confirmInboundTorrentIfNeeded(url.lastPathComponent) { [weak self] in
            guard let self else { return }
            self.showTorrentsDrawer()
            TorrentDaemonClient.shared.addTorrent(
                fileAt: url.path, savePath: TorrentSavePath.resolve(self.prefs.torrentDownloadPath))
        }
    }

    /// Open the Torrents drawer and add a magnet: link handed in by another app (the magnet: URL
    /// scheme). Optionally confirms first; downloads go to the configured folder.
    func addMagnetToPanel(_ uri: String) {
        confirmInboundTorrentIfNeeded(magnetDisplayName(uri)) { [weak self] in
            guard let self else { return }
            self.showTorrentsDrawer()
            TorrentDaemonClient.shared.addMagnet(
                uri, savePath: TorrentSavePath.resolve(self.prefs.torrentDownloadPath))
        }
    }

    /// When "confirm inbound torrents" is on, ask before adding a link another app handed us; else add
    /// straight away. The user's in-app Add (drawer) never routes through here, so pasting a magnet
    /// yourself is never gated -- only links pushed in from outside.
    private func confirmInboundTorrentIfNeeded(_ label: String, add: @escaping () -> Void) {
        guard prefs.confirmInboundTorrents else {
            add()
            return
        }
        let alert = NSAlert()
        alert.messageText = L(
            "torrents.confirmInbound.title", "Add this download from another app?")
        alert.informativeText = String(
            format: L(
                "torrents.confirmInbound.body", "Another app asked Pathem to download:\n\n%@"),
            label)
        alert.addButton(withTitle: L("torrents.confirmInbound.add", "Add"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        Task { @MainActor in
            if await self.presentSheet(alert) == .alertFirstButtonReturn { add() }
        }
    }

    /// A short, readable label for a magnet URI in the confirmation prompt: its display-name (`dn`)
    /// parameter if present, else a truncated form of the URI.
    private func magnetDisplayName(_ uri: String) -> String {
        if let components = URLComponents(string: uri),
            let dn = components.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty
        {
            return dn
        }
        return uri.count > 80 ? String(uri.prefix(80)) + "…" : uri
    }

    /// Show or hide the Torrents transfer drawer (docked at the bottom, like the terminal).
    func toggleTorrentsDrawer() {
        if torrentDrawer.view.isHidden { showTorrentsDrawer() } else { hideTorrentsDrawer() }
    }

    /// Reveal the drawer (idempotent) and start it receiving live updates. The drawer is a
    /// fixed-height arranged view in `mainStack`, so unhiding it reflows the stack: the browser
    /// split gives up the bottom 220pt and the drawer fills it. No divider math needed.
    func showTorrentsDrawer() {
        guard torrentDrawer.view.isHidden else { return }
        torrentDrawer.hostWindow = view.window
        torrentDrawer.view.isHidden = false
        torrentDrawer.activate()
        view.layoutSubtreeIfNeeded()
    }

    func hideTorrentsDrawer() {
        guard !torrentDrawer.view.isHidden else { return }
        torrentDrawer.deactivate()
        torrentDrawer.view.isHidden = true
        view.layoutSubtreeIfNeeded()
    }

    /// The selected torrent changed in the drawer. If the detail view is open, follow the selection.
    func torrentSelectionChanged(_ status: TorrentSession.Status?) {
        if !torrentDetail.isHidden, let status { torrentDetail.show(status) }
    }

    /// Open the detail view (Overview / Files / Peers / Trackers) over the pane area for a torrent.
    func showTorrentDetail(_ status: TorrentSession.Status) {
        torrentDetail.isHidden = false
        torrentDetail.show(status)
    }

    /// Close the detail view and return to the file browser.
    func hideTorrentDetail() {
        torrentDetail.hide()
        torrentDetail.isHidden = true
    }
}

@MainActor
extension BrowserViewController {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makeCreateTorrentDialog(source: URL) -> (NSAlert, NSTextField, NSButton) {
        let alert = NSAlert()
        alert.messageText = String(
            format: L("torrents.create.title", "Create Torrent from “%@”"), source.lastPathComponent
        )
        alert.informativeText = L(
            "torrents.create.message",
            "Optionally add a tracker. A private torrent won't use DHT or peer exchange.")
        alert.addButton(withTitle: L("torrents.create.next", "Choose Location…"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let tracker = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        tracker.placeholderString = L("torrents.create.tracker", "Tracker URL (optional)")
        let privateCheck = NSButton(
            checkboxWithTitle: L("torrents.create.private", "Private torrent"), target: nil,
            action: nil)
        let accessory = NSStackView(views: [tracker, privateCheck])
        accessory.orientation = .vertical
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 54)
        alert.accessoryView = accessory
        return (alert, tracker, privateCheck)
    }
}

@MainActor
extension BrowserViewController {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makeTorrentSaveDialog(
        source: URL, offerSuggestions: Bool, generateAutomatically: Bool = true
    ) -> (NSSavePanel, FilenameSuggestionController?) {
        let save = NSSavePanel()
        save.nameFieldStringValue = source.lastPathComponent + ".torrent"
        save.allowedContentTypes = [
            UTType(filenameExtension: "torrent")
                ?? UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)
        ]
        // Save suggestions share the same explicit-accept rule as rename; model latency
        // must never overwrite a filename the user is currently typing.
        let nameField = NSTextField(string: save.nameFieldStringValue)
        let suggestion =
            offerSuggestions
            ? FilenameSuggestionController(
                field: nameField, url: source, dataless: false, extensionOverride: "torrent",
                generateAutomatically: generateAutomatically) : nil
        suggestion?.onApply = { [weak save] name in save?.nameFieldStringValue = name }
        save.accessoryView = suggestion?.view
        return (save, suggestion)
    }
}
