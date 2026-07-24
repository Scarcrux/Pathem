import AppKit
import PathemEngine

// On-device AI actions: suggest a file name, summarize a folder, and the natural-language command
// bar (resolve a request to a command via the Foundation model, else the engine heuristic). Split
// out of BrowserViewController; the `aiBar` presenter and `externalOutput` panel stay on core (they
// are stored properties).
@MainActor
extension BrowserViewController {
    /// Suggest a new name for the single selected file with the on-device model, prefilling a
    /// standard rename sheet. The sheet opens immediately (name preselected) and the suggestion
    /// fills in when it lands, so the model's latency never blocks the UI. Applying goes through
    /// the normal rename + undo path.
    func aiRenameSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first, !entry.isDirectory
        else { NSSound.beep(); return }
        guard AIAssistant.isAvailable else {
            presentInfo(L("ai.unavailableTitle", "On-device AI unavailable"), AIAssistant.availability.reason)
            return
        }
        let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
        let url = directory.appendingPathComponent(entry.name)
        let ext = (entry.name as NSString).pathExtension

        let alert = NSAlert()
        alert.messageText = String(format: L("ai.renameTitle", "AI Rename “%@”"), entry.name)
        alert.informativeText = L("ai.renameHint", "Suggesting a name… you can edit it or type your own.")
        alert.addButton(withTitle: L("bvc.renameButton", "Rename"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // Fetch the suggestion concurrently and drop it into the field when it arrives.
        Task { @MainActor in
            let preview = await Task.detached { Self.textPreview(of: url) }.value
            guard let base = await AIAssistant.suggestName(currentName: entry.name, content: preview) else { return }
            guard field.window != nil else { return }  // sheet already dismissed
            field.stringValue = ext.isEmpty ? base : "\(base).\(ext)"
            field.selectText(nil)
        }

        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }
            do {
                try FileOperations.rename(entry.name, to: newName, in: directory)
                self.registerRenameUndo(from: newName, to: entry.name, in: directory)
                pane.reloadIfShowingListing()
                pane.select(name: newName)
            } catch {
                self.presentFailures(
                    [FileOperations.Failure(name: entry.name, reason: error.localizedDescription)],
                    title: L("bvc.renameFailed", "Rename failed"))
            }
        }
    }

    /// Summarize the current folder's contents with the on-device model, shown in the output panel.
    func aiSummarizeFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        guard AIAssistant.isAvailable else {
            presentInfo(L("ai.unavailableTitle", "On-device AI unavailable"), AIAssistant.availability.reason)
            return
        }
        let folder = pane.currentURL
        let names = pane.entries.map(\.name)
        externalOutput.present(
            title: String(format: L("ai.summaryTitle", "Summary of %@"), folder.lastPathComponent),
            loading: L("ai.summarizing", "Summarizing…")
        ) {
            await AIAssistant.summarizeFolder(folderName: folder.lastPathComponent, itemNames: names)
                ?? L("ai.summaryFailed", "Couldn’t generate a summary.")
        }
    }

    /// A short text preview of a file for AI naming: up to 4 KB of a text-like file, else `nil`.
    /// Kept conservative (by extension) so we never read a huge binary into memory.
    nonisolated static func textPreview(of url: URL) -> String? {
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log",
            "swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp", "java", "sh",
            "html", "css", "rtf", "tex", "org", "ini", "toml", "conf",
        ]
        guard textExtensions.contains(url.pathExtension.lowercased()),
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /// Open the natural-language command bar.
    func showAICommandBar() {
        guard let window = view.window else { return }
        aiBar.present(
            over: window,
            resolve: { [weak self] query in await self?.resolveCommand(query) ?? nil },
            run: { [weak self] id in self?.commands.perform(id) })
    }

    /// Resolve a natural-language request to a command: the on-device Foundation
    /// Model when available, the engine heuristic otherwise.
    private func resolveCommand(_ query: String) async -> (id: String, title: String)? {
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        if #available(macOS 26.0, *),
            let id = await FoundationModelMatcher.match(query, to: items),
            let command = commands.command(id)
        {
            return (command.id, command.title)
        }
        if let id = CommandResolver.resolve(query, commands: items), let command = commands.command(id) {
            return (command.id, command.title)
        }
        return nil
    }
}
