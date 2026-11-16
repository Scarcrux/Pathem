import AppKit
import PathemEngine

// Selection actions that reveal or inspect rather than mutate: Reveal in Finder / in Pathem,
// Show Original (for an alias/symlink), Get Info, and Download (pull a remote selection local).
// Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Explicitly browse a package; normal Open continues to hand it to its application.
    func showPackageContents() {
        guard let pane = activePane, !pane.isRemote else { return }
        let urls = pane.selectedLocalURLs()
        guard urls.count == 1, FileContextMenuController.isPackage(urls[0]) else { return }
        pane.navigate(to: urls[0])
    }
    func revealSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let urls = pane.selectedLocalURLs()  // location-aware (reveals the real file in smart views)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.currentURL] : urls)
    }

    /// Reveal the selection in place: navigate the active pane to the file's real folder and
    /// select it there, instead of handing off to Finder. Most useful from search and smart
    /// views, where the file lives outside the folder currently on screen.
    func revealSelectionInPathem() {
        if blockedByRemote() { return }
        guard let pane = activePane, let target = pane.selectedLocalURLs().first else { return }
        pane.reveal(target)
    }

    /// Jump to the original of a selected alias or symlink: resolve its target and reveal it
    /// (navigate to the target's folder and select it), like Finder's Show Original.
    func showOriginal() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first else {
            NSSound.beep()
            return
        }
        guard let target = Self.resolveOriginal(of: url) else {
            presentInfo(
                L("bvc.showOriginalNoneTitle", "No original to show"),
                L(
                    "bvc.showOriginalNoneBody",
                    "This item isn’t an alias or symlink, or its original can’t be found (it may have been moved or deleted)."
                ))
            return
        }
        pane.reveal(target)
    }

    /// Resolve an alias file or symlink to its target URL, or nil if it's neither (or unresolvable).
    static func resolveOriginal(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if values?.isAliasFile == true {
            return try? URL(resolvingAliasFileAt: url, options: [])
        }
        if values?.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath()
            return resolved.path == url.path ? nil : resolved
        }
        return nil
    }

    /// Get Info on the selection, or on the current folder when nothing is selected.
    func showInfo() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let selected = pane.selectedLocalURLs()  // location-aware
        let urls = selected.isEmpty ? [pane.currentURL] : selected
        if prefs.useFinderGetInfo {
            Self.openFinderGetInfo(urls)
        } else {
            infoInspector.present(urls: urls, over: view.window)
        }
    }

    /// Open Finder's own Get Info window for each URL (the optional default-app path).
    private static func openFinderGetInfo(_ urls: [URL]) {
        let items = urls.map {
            "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        .joined(separator: ", ")
        let script = """
            tell application "Finder"
                activate
                open information window of every item of {\(items)}
            end tell
            """
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }

    /// Pull down online-only (dataless) cloud files. The provider materializes
    /// them; the watcher refreshes the badge as they land.
    func downloadSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane, !pane.isRemote else { return }
        for url in pane.selectedLocalURLs()  // location-aware
        where CloudItemActions(urls: [url]).showsDownloadNow {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Which iCloud entries apply to the active pane's selection (nothing for a remote or smart
    /// listing). The one source for both commands' enabled rules.
    func cloudActions() -> CloudItemActions {
        guard let pane = activePane, !pane.isRemote else { return CloudItemActions(for: []) }
        // Menu validation calls this on the main thread, and each item costs two metadata
        // reads, so a very large selection is judged by a bounded sample, as the context menu's
        // own per-item rules are.
        return CloudItemActions(urls: Array(pane.selectedLocalURLs().prefix(2000)))
    }
}
