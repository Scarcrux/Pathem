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
        if let refusal = semanticRefusal(for: pane) {
            // Search needs a single local list. Say why, in the status line, instead of beeping.
            if !query.isEmpty { pane.flashStatus(refusal, isError: true) }
            return
        }
        pane.searchQuery = query  // remember per pane so the toolbar button resyncs on focus change
        updateSearchButton(query: query)
        guard !query.isEmpty else {
            pane.endSemanticSearch()  // cleared search: restore the listing, selection and scroll
            return
        }
        let directory = pane.currentURL
        // Only act for the very pane we searched, still on that folder AND still on this query.
        // Without the query check, a debounced search whose text was then cleared or changed
        // would land stale states or results over the restored listing.
        let isCurrent: @MainActor () -> Bool = { [weak self, weak pane] in
            guard let self, let pane else { return false }
            return self.activePane === pane && pane.currentURL == directory
                && pane.searchQuery == query
        }
        // The index belongs to the folder, not the query: keep adopting it after the text changes
        // so the newer query (which awaits the same build) still finds it.
        let indexStillWanted: @MainActor () -> Bool = { [weak self] in
            self?.activePane?.currentURL == directory
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.semanticSearch.rank(
                query: query, in: directory, isCurrent: indexStillWanted,
                phase: { phase in
                    guard isCurrent() else { return }
                    pane.setSearchPhase(
                        phase == .indexing
                            ? L("semantic.indexing", "Indexing…")
                            : L("semantic.ranking", "Ranking…"))
                })
            guard isCurrent() else {
                // Another pane took focus while this one searched. Its "Indexing…" would
                // otherwise stay in the status line for good, since nothing else clears it.
                // A newer query or another folder owns the phase, so leave those alone.
                if pane.currentURL == directory, pane.searchQuery == query {
                    pane.setSearchPhase(nil)
                }
                return
            }
            switch outcome {
            case .ranked(let ranked, let cap):
                pane.showResults(
                    ranked,
                    note: cap.map {
                        String(
                            format: L(
                                "semantic.capped", "Only the first %d items were indexed."), $0)
                    })
            case .failed(let reason):
                pane.showSemanticFailure(
                    String(
                        format: L(
                            "semantic.indexFailed",
                            "Semantic search could not index this folder: %@"), reason))
            case .stale:
                pane.setSearchPhase(nil)
            }
        }
    }

    /// Why semantic search cannot run on `pane`, or nil when it can.
    func semanticRefusal(for pane: PaneController) -> String? {
        if pane.isRemote {
            return L(
                "semantic.refuseRemote", "Semantic search works on local folders, not remote ones.")
        }
        if pane.isShowingSmartResults {
            return L(
                "semantic.refuseSmart",
                "Semantic search is not available over search results or smart lists. Open a folder first."
            )
        }
        if pane.viewMode == .column {
            return L(
                "semantic.refuseColumn",
                "Semantic search is not available in column view. Switch to list, icon or gallery view."
            )
        }
        return nil
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
