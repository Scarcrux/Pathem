import AppKit
import PathemEngine

// Git write operations (commit / push / pull) and the App Deleter (uninstall an app and
// its leftover support files), split out of BrowserViewController.
extension BrowserViewController {
    // MARK: - Git write (commit / push / pull)

    func gitCommit() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let window = view.window
        else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        Task { @MainActor [self] in
            let staged = await GitOps.stageAll(in: folder)
            guard staged.ok else {
                self.presentInfo(L("git.notRepoTitle", "Not a git repository"), staged.output)
                return
            }
            guard await GitOps.hasStagedChanges(in: folder) else {
                self.presentInfo(
                    L("git.nothingTitle", "Nothing to commit"),
                    L("git.nothingBody", "There are no changes to commit."))
                return
            }
            self.commitController.present(
                over: window, repo: folder.lastPathComponent,
                canSuggest: AIAvailability.isAvailable,
                suggest: { [weak self] in await self?.suggestCommit(folder: folder) ?? nil },
                commit: { [weak self] message in self?.performCommit(message, in: folder) })
        }
    }

    private func suggestCommit(folder: URL) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return await aiCommitMessage(diff: await GitOps.stagedDiff(in: folder))
        }
        #endif
        return nil
    }

    private func performCommit(_ message: String, in folder: URL) {
        Task { @MainActor in
            let result = await GitOps.commit(message, in: folder)
            self.reloadBothSides()
            if !result.ok {
                self.presentInfo(L("git.commitFailedTitle", "Commit failed"), result.output)
            }
        }
    }

    func gitPushPull(push: Bool) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        Task { @MainActor in
            let result = push ? await GitOps.push(in: folder) : await GitOps.pull(in: folder)
            self.reloadBothSides()
            if result.ok {
                self.presentInfo(
                    push ? L("git.pushedTitle", "Pushed") : L("git.pulledTitle", "Pulled"),
                    result.output.isEmpty ? L("git.upToDate", "Already up to date.") : result.output
                )
            } else {
                self.presentInfo(
                    push
                        ? L("git.pushFailedTitle", "Push failed")
                        : L("git.pullFailedTitle", "Pull failed"),
                    result.output)
            }
        }
    }

    // MARK: - App Deleter (remove an app and its leftover support files)

    func deleteAppWithLeftovers() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first,
            entry.name.hasSuffix(".app"), let window = view.window
        else {
            NSSound.beep()
            return
        }
        let appURL = pane.currentURL.appendingPathComponent(entry.name)
        Task { @MainActor [self] in
            let leftovers = await Task.detached { AppLeftovers.find(forApp: appURL) }.value
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let total = leftovers.reduce(Int64(0)) { $0 + $1.size }
            let alert = NSAlert()
            alert.messageText = String(
                format: L("appdel.title", "Move %@ to the Trash?"), entry.name)
            if leftovers.isEmpty {
                alert.informativeText = L("appdel.noneBody", "No related support files were found.")
            } else {
                let list = leftovers.prefix(12).map {
                    "  • " + ($0.path as NSString).lastPathComponent
                }
                .joined(separator: "\n")
                alert.informativeText = String(
                    format: L("appdel.body", "Also remove %d related files (%@):\n%@"),
                    leftovers.count, formatter.string(fromByteCount: total),
                    list + (leftovers.count > 12 ? "\n  …" : ""))
            }
            alert.addButton(withTitle: L("bvc.moveToTrashAction", "Move to Trash"))
            alert.addButton(withTitle: L("common.cancel", "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                let urls = [appURL] + leftovers.map { URL(fileURLWithPath: $0.path) }
                let result = FileOperations.trash(urls: urls)
                self.reloadBothSides()
                if !result.trashed.isEmpty { self.registerTrashUndo(result.trashed) }
                if !result.failures.isEmpty {
                    self.presentFailures(
                        result.failures, title: L("bvc.moveToTrashFailed", "Move to Trash failed"))
                }
            }
        }
    }
}
