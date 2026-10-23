import AppKit
import Darwin
import PathemEngine

// On-device AI actions: suggest a file name, summarize a folder, and the natural-language command
// bar (resolve a request to a command via the Foundation model, else the engine heuristic). Split
// out of BrowserViewController; the `aiBar` presenter and `externalOutput` panel stay on core (they
// are stored properties).
@MainActor
extension BrowserViewController {
    /// Open the shared rename sheet with an on-device suggestion. The explicit Use action
    /// avoids overwriting typing; confirmation follows the normal extension-warning + undo path.
    func aiRenameSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first,
            !entry.isDirectory
        else {
            NSSound.beep()
            return
        }
        guard AIAssistant.isAvailable else {
            presentInfo(
                L("ai.unavailableTitle", "On-device AI unavailable"),
                AIAssistant.availability.reason)
            return
        }
        renameSelection(suggestions: true)
    }

    /// Summarize the current folder's contents with the on-device model, shown in the output panel.
    func aiSummarizeFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        guard AIAssistant.isAvailable else {
            presentInfo(
                L("ai.unavailableTitle", "On-device AI unavailable"),
                AIAssistant.availability.reason)
            return
        }
        let folder = pane.currentURL
        let names = pane.entries.map(\.name)
        externalOutput.present(
            title: String(format: L("ai.summaryTitle", "Summary of %@"), folder.lastPathComponent),
            loading: L("ai.summarizing", "Summarizing…")
        ) {
            await AIAssistant.summarizeFolder(
                folderName: folder.lastPathComponent, itemNames: names)
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
        var before = stat()
        guard textExtensions.contains(url.pathExtension.lowercased()),
            lstat(url.path, &before) == 0,
            mayReadTextPreview(mode: before.st_mode, flags: before.st_flags)
        else { return nil }  // never follow a symlink, hydrate a placeholder, or open a FIFO
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
            mayReadTextPreview(mode: opened.st_mode, flags: opened.st_flags)
        else { return nil }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    nonisolated static func mayReadTextPreview(mode: mode_t, flags: UInt32) -> Bool {
        mode & S_IFMT == S_IFREG && flags & UInt32(0x4000_0000) == 0
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
        if let id = CommandResolver.resolve(query, commands: items),
            let command = commands.command(id)
        {
            return (command.id, command.title)
        }
        return nil
    }
}
