import AppKit
import PathemEngine

// On-device semantic search (free, off-main): re-rank the active folder by similarity to a query,
// and keep the toolbar search button in sync. The per-folder index is built lazily on the first
// search (SemanticSearchController.rank -> ensureIndex), so opening a folder never reads or embeds
// its contents. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Re-rank the active pane's folder by semantic similarity to the query.
    /// An empty query restores the normal directory listing. All embedding runs
    /// off the main thread, so the UI never blocks. Fed live (debounced) by the
    /// overlay's search mode.
    func performSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pane = activePane else { return }
        guard !pane.isRemote, !pane.isShowingSmartResults, pane.viewMode != .column else {
            if !query.isEmpty { NSSound.beep() }  // search needs a single local list
            return
        }
        pane.searchQuery = query  // remember per pane so the toolbar button resyncs on focus change
        updateSearchButton(query: query)
        guard !query.isEmpty else {
            if pane.isShowingSearchResults { pane.reload() }  // cleared search, restore the listing
            return
        }
        let directory = pane.currentURL
        Task { [weak self] in
            guard let self else { return }
            let ranked = await self.semanticSearch.rank(
                query: query, in: directory,
                isCurrent: { [weak self] in self?.activePane?.currentURL == directory })
            // Only adopt results if the very pane we searched is still active, on that folder,
            // AND still on this query. Without the query check, a debounced search whose text was
            // then cleared or changed would land stale results over the restored listing.
            guard let ranked, self.activePane === pane, pane.currentURL == directory,
                pane.searchQuery == query
            else { return }
            pane.showResults(ranked)
        }
    }

    @objc func searchButtonTapped() { showFileSearch() }

    /// Reflect the active pane's query on the toolbar button (its title doubles as the
    /// visible search state, since the overlay itself is transient).
    func updateSearchButton(query: String) {
        searchButton.title = " " + (query.isEmpty ? L("bvc.searchPlaceholder", "Search") : query)
        searchButton.contentTintColor =
            query.isEmpty ? .secondaryLabelColor : ThemeManager.shared.accent
    }
}
