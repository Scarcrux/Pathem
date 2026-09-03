import AppKit
import PathemEngine

// Command / selection overlays: the command-and-search palette, the batch-rename sheet, and
// select-by-pattern. Split out of BrowserViewController to shrink the god-object (5.1).
extension BrowserViewController {
    /// Open the search-and-command overlay over the current window. `prefill` picks the
    /// opening mode: "" is search (Cmd-F), ">" is commands (Cmd-K); either way it's one
    /// widget and the prefix switches modes mid-flight. Chosen commands dispatch through
    /// the registry; search queries rank the active pane live.
    func showPalette(prefill: String = ">") {
        guard let window = view.window else { return }
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        palette.present(
            commands: items,
            prefill: prefill,
            onRun: { [weak self] id in self?.commands.perform(id) },
            onNavigate: { [weak self] url in self?.activePane?.navigate(to: url) },
            onSemantic: { [weak self] query in self?.performSearch(query) },
            over: window)
    }

    /// Open the batch-rename sheet for the active pane's selection.
    func showBatchRename() {
        if blockedByRemoteOrSmart() { return }  // operates within one folder
        guard let window = view.window, let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        let existing = Set(pane.entries.map(\.name))
        batchRename.present(names: names, in: pane.currentURL, existing: existing, over: window) {
            [weak self] in self?.activePane?.reloadIfShowingListing()
        }
    }

    /// Select items in the active pane by a name pattern (glob / regex / substring),
    /// replacing, extending, or trimming the current selection.
    func selectByPattern() {
        guard let pane = activePane, let window = view.window else { NSSound.beep(); return }
        SelectByPatternSheet.present(over: window) { query, mode in
            pane.applySelection(query, mode: mode)
        }
    }
}
