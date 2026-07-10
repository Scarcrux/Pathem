import AppKit
import TorrentKit

@MainActor
extension BrowserViewController {
    /// Add every selected .torrent to the Torrents panel.
    func addSelectedTorrents() {
        let urls = selectedTorrentURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        for url in urls { addTorrentToPanel(url) }
    }

    /// Create a .torrent from the selected file or folder: prompt for a tracker + private flag,
    /// choose where to save, then hash off the main thread and reveal the result.
    func createTorrentFromSelection() {
        guard let source = selectedSingleLocalURL else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.messageText = String(format: L("torrents.create.title", "Create Torrent from “%@”"), source.lastPathComponent)
        alert.informativeText = L("torrents.create.message", "Optionally add a tracker. A private torrent won't use DHT or peer exchange.")
        alert.addButton(withTitle: L("torrents.create.next", "Choose Location…"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let tracker = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        tracker.placeholderString = L("torrents.create.tracker", "Tracker URL (optional)")
        let privateCheck = NSButton(checkboxWithTitle: L("torrents.create.private", "Private torrent"), target: nil, action: nil)
        let accessory = NSStackView(views: [tracker, privateCheck])
        accessory.orientation = .vertical
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 54)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trackerText = tracker.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = TorrentCreator.Options(
            trackers: trackerText.isEmpty ? [] : [trackerText],
            isPrivate: privateCheck.state == .on,
            creationDate: Date())

        let save = NSSavePanel()
        save.nameFieldStringValue = source.lastPathComponent + ".torrent"
        save.allowedFileTypes = ["torrent"]
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
                    fail.informativeText = "\(error)"
                    fail.runModal()
                }
            }
        }
    }

    /// Copy the magnet links of the selected .torrent files to the clipboard.
    func copySelectedMagnetLinks() {
        let links = selectedTorrentURLs.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url), let torrent = try? TorrentFile.parse(data) else { return nil }
            return torrent.magnetLink
        }
        guard !links.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    /// Open the Torrents panel and add a .torrent (or magnet). Downloads go to the Downloads folder.
    func addTorrentToPanel(_ url: URL) {
        torrents.present()
        let savePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        TorrentDaemonClient.shared.addTorrent(fileAt: url.path, savePath: savePath)
    }

    /// Open the Torrents panel and add a magnet: link (from the magnet: URL scheme).
    func addMagnetToPanel(_ uri: String) {
        torrents.present()
        let savePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        TorrentDaemonClient.shared.addMagnet(uri, savePath: savePath)
    }
}
