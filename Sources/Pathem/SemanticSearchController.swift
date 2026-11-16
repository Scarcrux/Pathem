import Foundation
import PathemEngine

/// Owns the on-device semantic-search index for one folder: builds and caches it off the
/// main thread, and ranks a folder's entries against a query. Split out of
/// BrowserViewController so the index cache and embedding orchestration live in one small,
/// self-contained collaborator instead of as loose state on the god-object. The browser
/// keeps the UI (which pane, showing results); this keeps the data.
///
/// `isCurrent` closures let the caller cancel adopting a result when the user has since
/// navigated away, without this type knowing anything about panes.
@MainActor
final class SemanticSearchController {
    private var cachedDir: URL?
    private var cachedIndex: FolderSemanticIndex?
    private var cachedEntries: [FileEntry]?
    private var cachedCap: Int?  // the cap the cached index hit, when the folder had more items
    private var buildTask: Task<String?, Never>?  // the in-flight build (its failure), so bursts coalesce
    private var buildingDir: URL?
    private var cachedRecursive = false
    private var buildingRecursive = false
    nonisolated static let defaultMaxItems = 5_000

    /// How many items one index covers. A var so a test can use a small cap.
    var maxItems = SemanticSearchController.defaultMaxItems

    /// The three slow steps, replaceable so a test can answer each on command instead of
    /// running the on-device model. The defaults are the real enumeration, embedding and ranking.
    struct Backend: Sendable {
        var entries: @Sendable (URL, _ recursive: Bool) async throws -> [FileEntry]
        var index: @Sendable ([FileEntry], URL, Int, Bool) async -> FolderSemanticIndex
        var rank: @Sendable (String, FolderSemanticIndex) async -> [Int]

        static let live = Backend(
            entries: { directory, recursive in
                try await Task.detached {
                    guard recursive else {
                        return try BulkEnumerator().entries(of: directory, includingHidden: false)
                    }
                    // One past the cap, so a tree larger than the index covers is visible as such.
                    return FlatEnumerator.entries(
                        of: directory, includingHidden: false, includeFolders: true,
                        maxItems: SemanticSearchController.defaultMaxItems + 1
                    ).entries
                }.value
            },
            index: { entries, directory, maxItems, ocr in
                await Task.detached {
                    SemanticSearcher.index(
                        entries, in: directory, maxItems: maxItems, ocrImages: ocr,
                        pdf: PDFTextExtractor())  // app-side, since PDFKit links AppKit
                }.value
            },
            rank: { query, index in
                await Task.detached { SemanticSearcher.rank(query: query, in: index) }.value
            })
    }
    var backend = Backend.live

    enum Phase: Sendable { case indexing, ranking }

    enum Outcome {
        /// Entries in ranked order; `indexCap` is set when the folder had more items than the
        /// index covers, so only the first `indexCap` could be ranked.
        case ranked([FileEntry], indexCap: Int?)
        /// The index could not be built; `reason` is short and fit to show.
        case failed(reason: String)
        /// The folder or query moved on; show nothing.
        case stale
    }

    /// Include OCR'd image text when indexing (mirrors the search-OCR preference).
    var includeOCR = false

    /// The folder the cache currently holds, if any (so a caller can skip a redundant
    /// pre-index of the same folder).
    var cachedDirectory: URL? { cachedDir }

    /// Rank `directory`'s entries by semantic similarity to `query`. `phase` is told when the
    /// folder starts being indexed (only if there is no cached index) and when ranking starts.
    func rank(
        query: String, in directory: URL, recursive: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool,
        phase: @escaping @MainActor (Phase) -> Void = { _ in }
    ) async -> Outcome {
        func cacheMatches() -> Bool {
            cachedIndex != nil && cachedDir == directory && cachedRecursive == recursive
        }
        // A concurrent build for another key (the panel's subfolder toggle, a different folder)
        // can overwrite the cache after ours lands, so look again a couple of times while the
        // caller still wants this result, rather than report a stale miss for a live query.
        var attempts = 0
        while !cacheMatches(), attempts < 3, attempts == 0 || isCurrent() {
            if attempts == 0 { phase(.indexing) }
            attempts += 1
            if let reason = await ensureIndex(
                for: directory, recursive: recursive, isCurrent: isCurrent)
            {
                return .failed(reason: reason)
            }
        }
        guard cacheMatches(), let index = cachedIndex, let entries = cachedEntries else {
            return .stale
        }
        let cap = cachedCap
        phase(.ranking)
        let order = await backend.rank(query, index)
        return .ranked(order.compactMap { $0 < entries.count ? entries[$0] : nil }, indexCap: cap)
    }

    /// Drop the cache (e.g. a preference that affects indexing changed, or the folder changed
    /// on disk). Also drops the in-flight build so it can't adopt a now-stale result.
    func invalidate() {
        buildTask?.cancel()
        buildTask = nil
        buildingDir = nil
        cachedDir = nil
        cachedIndex = nil
        cachedEntries = nil
        cachedCap = nil
    }

    /// Enumerate and embed `directory` off the main thread, adopting the result only if
    /// `isCurrent()` still holds (the user hasn't navigated away). Concurrent calls for the same
    /// folder (e.g. rapid searches) await the one in-flight build instead of each starting their
    /// own embed of up to `maxItems` files. Returns why the build failed, or nil on success (or
    /// when the result was dropped as stale, which the caller sees as no cached index).
    private func ensureIndex(
        for directory: URL, recursive: Bool, isCurrent: @escaping @MainActor () -> Bool
    ) async
        -> String?
    {
        guard cachedDir != directory || cachedRecursive != recursive || cachedIndex == nil else {
            return nil
        }
        if let task = buildTask, buildingDir == directory, buildingRecursive == recursive {
            return await task.value
        }
        let maxItems = self.maxItems
        let ocr = includeOCR
        let backend = self.backend
        let task = Task { @MainActor [weak self] () -> String? in
            let dirEntries: [FileEntry]
            do {
                dirEntries = try await backend.entries(directory, recursive)
            } catch {
                return error.localizedDescription
            }
            let built = await backend.index(dirEntries, directory, maxItems, ocr)
            guard let self, !Task.isCancelled, isCurrent() else { return nil }
            // An empty index over a non-empty folder means nothing could be embedded: the
            // on-device model is not ready. Report it rather than cache an index that matches
            // nothing, so a later search retries.
            if built.isEmpty, !dirEntries.isEmpty {
                return L(
                    "semantic.noModel", "the on-device language model is not available yet")
            }
            self.cachedDir = directory
            self.cachedRecursive = recursive
            self.cachedEntries = dirEntries
            self.cachedIndex = built
            self.cachedCap = dirEntries.count > maxItems ? maxItems : nil
            return nil
        }
        buildingDir = directory
        buildingRecursive = recursive
        buildTask = task
        let failure = await task.value
        if buildingDir == directory, buildingRecursive == recursive {
            buildTask = nil
            buildingDir = nil
        }
        return failure
    }
}
