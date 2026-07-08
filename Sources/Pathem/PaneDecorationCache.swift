import AppKit
import PathemEngine

/// Per-view cache of the two async decorations a pane item carries: Finder tag colors and git
/// working-tree state. Owns the off-main tag read and the git-state map so every non-list view
/// (icon, gallery, column) renders them identically without copying the logic — the list keeps
/// its own inline cache for now. Everything is keyed by `PaneItemKey.path`.
@MainActor
final class PaneDecorationCache {
    private var tagCache: [String: [FileTag.Color]] = [:]
    private var gitStates: [String: GitFileState] = [:]
    private var generation = 0

    /// Called on the main thread after an async tag read changes the visible dots; the owning
    /// view reloads here. Set once — kept as stored state (not a per-call closure) so the
    /// background read never captures a main-actor closure, which Swift 6 would reject.
    var onTagsChanged: (() -> Void)?

    /// Store new git states; returns true when they actually changed, so the caller only reloads
    /// when something visible moved.
    @discardableResult
    func setGitStates(_ states: [String: GitFileState]) -> Bool {
        guard states != gitStates else { return false }
        let hadAny = !gitStates.isEmpty
        gitStates = states
        return hadAny || !states.isEmpty
    }

    func gitState(for entry: FileEntry, in directory: URL?) -> GitFileState? {
        guard !gitStates.isEmpty else { return nil }
        return gitStates[PaneItemKey.path(for: entry, in: directory)]
    }

    /// Cached tag colors for an item, read only from the cache so the cell path never does a
    /// filesystem syscall on the main thread. Cross-folder search results (nil directory) show none.
    func tagColors(for entry: FileEntry, in directory: URL?) -> [FileTag.Color] {
        guard directory != nil else { return [] }
        return tagCache[PaneItemKey.path(for: entry, in: directory)] ?? []
    }

    func invalidateTags() { tagCache.removeAll() }

    /// Read tag colors off the main thread for `entries` in `directory`, then fire `onTagsChanged`
    /// if any visible dot changed. No-op (clears) when directory is nil (a cross-folder search).
    func refreshTags(entries: [FileEntry], directory: URL?) {
        guard let directory else { tagCache.removeAll(); return }
        refreshTags(groups: [(entries, directory)])
    }

    /// Multi-folder variant for the column browser: reads tags across every open column at once
    /// and replaces the cache with their union, so one drilled column's refresh doesn't clobber
    /// another's. Stale reads (a newer refresh started, or the view moved on) are dropped via the
    /// generation guard. Only Sendable data (and a weak reference to this main-actor class) crosses
    /// the thread boundary, so no closure is sent.
    func refreshTags(groups: [(entries: [FileEntry], directory: URL)]) {
        generation += 1
        let generation = self.generation
        let paths = groups.flatMap { group in group.entries.map { PaneItemKey.path(for: $0, in: group.directory) } }
        let known = tagCache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [String: [FileTag.Color]] = [:]
            result.reserveCapacity(paths.count)
            for path in paths {
                if let cached = known[path] {
                    result[path] = cached
                } else {
                    result[path] = FileTags.tags(of: URL(fileURLWithPath: path)).map(\.color).filter { $0 != .none }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                let hadDots = self.tagCache.contains { !$0.value.isEmpty }
                self.tagCache = result
                if hadDots || result.contains(where: { !$0.value.isEmpty }) { self.onTagsChanged?() }
            }
        }
    }
}
