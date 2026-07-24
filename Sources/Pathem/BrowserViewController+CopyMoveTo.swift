import AppKit
import PathemEngine

// Copy To / Move To an arbitrary folder, plus the recent-destinations list that turns a repeated
// "put it there again" into a single palette pick. Split out of BrowserViewController; the shared
// transfer plumbing (runTransfer / resolveThenTransfer) and the `recentDestinations` store stay on
// core.
@MainActor
extension BrowserViewController {
    static var recentDestinationsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("recent-destinations.json")
    }

    func loadRecentDestinations() {
        recentDestinations = (loadConfig([String].self, from: Self.recentDestinationsURL) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }  // drop folders that went away
        registerRecentDestinationCommands()
    }

    /// One palette command per recent destination, for each of copy and move, so a repeated
    /// "Copy To that place again" is a single palette pick. Rebuilt whenever the list changes.
    func registerRecentDestinationCommands() {
        for command in commands.all where command.id.hasPrefix("dest.recent.") {
            commands.unregister(command.id)
        }
        for (index, path) in recentDestinations.enumerated() {
            let name = (path as NSString).lastPathComponent
            let hasSel: () -> Bool = { [weak self] in self?.activePane?.selectedEntries.isEmpty == false }
            commands.register(
                .init(id: "dest.recent.copy.\(index)", title: String(format: L("bvc.copyToRecent", "Copy To: %@"), name), isEnabled: hasSel) {
                    [weak self] in self?.transferSelection(to: URL(fileURLWithPath: path), move: false)
                })
            commands.register(
                .init(id: "dest.recent.move.\(index)", title: String(format: L("bvc.moveToRecent", "Move To: %@"), name), isEnabled: hasSel) {
                    [weak self] in self?.transferSelection(to: URL(fileURLWithPath: path), move: true)
                })
        }
    }

    /// Prompt for a folder (starting at the most recent destination) and copy or move the
    /// active selection there.
    func copyOrMoveTo(move: Bool) {
        guard let pane = activePane, !pane.isRemote, let window = view.window else { NSSound.beep(); return }
        guard !pane.selectedLocalURLs().isEmpty else { NSSound.beep(); return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = move ? L("dest.moveHere", "Move Here") : L("dest.copyHere", "Copy Here")
        picker.message =
            move
            ? L("dest.moveMessage", "Choose a folder to move the selection into")
            : L("dest.copyMessage", "Choose a folder to copy the selection into")
        if let recent = recentDestinations.first { picker.directoryURL = URL(fileURLWithPath: recent) }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url, let self else { return }
            self.transferSelection(to: destination, move: move)
        }
    }

    /// Copy or move the active selection into `destination` (off-main, with the standard
    /// conflict prompt, progress sheet, and undo), then remember the destination.
    private func transferSelection(to destination: URL, move: Bool) {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        // Copying/moving into a folder that's already the parent is a no-op; also refuse
        // moving a folder into itself or its own subtree.
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        if urls.contains(where: {
            let p = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return destPath == p || destPath.hasPrefix(p + "/")
        }) {
            presentInfo(
                L("dest.invalidTitle", "Can’t put a folder inside itself"),
                L("dest.invalidBody", "Choose a destination that isn’t one of the selected folders or inside them."))
            return
        }

        let conflicts = FileOperations.conflicts(urls: urls, into: destination)
        resolveThenTransfer(urls: urls, into: destination, move: move, conflictCount: conflicts.count) { [weak self] outcome in
            guard let self else { return }
            self.reloadBothSides()
            if move { self.pruneSmartEntries(Set(outcome.performed.map(\.source.path))) }
            if !outcome.performed.isEmpty {
                self.registerUndo(
                    outcome.performed, actionName: move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
                self.recordDestination(destination)
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(
                    outcome.failures,
                    title: move ? L("bvc.moveFailed", "Move failed") : L("bvc.copyFailed", "Copy failed"))
            }
        }
    }

    private func recordDestination(_ url: URL) {
        recentDestinations = RecentDestinations.recording(url.path, into: recentDestinations)
        saveConfig(recentDestinations, to: Self.recentDestinationsURL)
        registerRecentDestinationCommands()
    }
}
