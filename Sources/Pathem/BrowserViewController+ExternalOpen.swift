import AppKit
import PathemEngine

// Opening items handed to Pathem from outside the app: Finder's "Open With" / Services, the
// `pathem open|reveal <path>` CLI, and the Photos-library browser. Split out of BrowserViewController
// to shrink the god-object (5.1).
extension BrowserViewController {
    /// Open a folder (or reveal a file) handed to Pathem by Finder's "Open With" or the Services
    /// menu, and bring the window forward.
    func openExternalFolder(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            presentInfo("Couldn’t open item", "The file or folder no longer exists.")
            return
        }
        // Bring the window up first: on a cold Finder-launch open, presentViewer's makeFirstResponder
        // is a no-op until the window is attached, which would leave the viewer overlay inert.
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if isDir.boolValue {
            activePane?.navigate(to: url)
        } else if url.pathExtension.lowercased() == "torrent" {
            addTorrentToPanel(url)  // a .torrent opened from Finder goes straight into the Torrents panel
        } else if DocumentPreviewView.isViewable(url) {
            // A PDF/image opened from Finder (e.g. with Pathem as its default app): show it in its
            // folder and present the built-in viewer, so double-clicking actually views the file.
            activePane?.reveal(url)
            activePane?.presentViewer(url)
        } else {
            activePane?.reveal(url)  // any other file: show it in its folder
            activePane?.flashStatus(
                "Selected \(url.lastPathComponent) — double-click to open it in its default app")
        }
    }

    /// Preview a file handed over through the typed `pathem://preview` contract. Unsupported
    /// formats are still revealed, but the failure is explicit rather than a silent no-op.
    func previewExternalItem(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            presentInfo("Couldn’t preview item", "The file no longer exists.")
            return
        }
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard !isDir.boolValue, DocumentPreviewView.isViewable(url) else {
            revealExternalItem(url)
            presentInfo(
                "Preview unavailable",
                "Pathem selected the item, but this file type does not have a read-only Pathem preview. Open it with its default application instead."
            )
            return
        }
        activePane?.reveal(url)
        activePane?.presentViewer(url)
    }

    /// Open the Photos-library browser (PhotoKit). Exports default to the active local folder so
    /// dragging or exporting a photo lands where you're browsing.
    func openPhotosBrowser() {
        let dir = activePane.flatMap { $0.isRemote ? nil : $0.currentURL }
        photosBrowser.show(exportDirectory: dir)
    }

    /// Reveal a path handed in by `pathem reveal <path>`: bring the window up and select the item in
    /// its parent folder. Unlike openExternalFolder, this selects a *folder* in its parent rather
    /// than navigating into it, so `reveal` and `open` stay distinct verbs.
    func revealExternalItem(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentInfo("Couldn’t reveal item", "The file or folder no longer exists.")
            return
        }
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        activePane?.reveal(url)  // navigate to the parent and select the item (file or folder)
    }
}
