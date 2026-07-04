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
    private static let maxItems = 5_000

    /// Include OCR'd image text when indexing (mirrors the search-OCR preference).
    var includeOCR = false

    /// The folder the cache currently holds, if any (so a caller can skip a redundant
    /// pre-index of the same folder).
    var cachedDirectory: URL? { cachedDir }

    /// Build/refresh the index for `directory` in the background (if not already cached), so
    /// the next search there is instant.
    func preIndex(_ directory: URL, isCurrent: @escaping @MainActor () -> Bool) {
        Task { await ensureIndex(for: directory, isCurrent: isCurrent) }
    }

    /// Rank `directory`'s entries by semantic similarity to `query`, returning the entries in
    /// ranked order (nil if the index couldn't be built or the folder moved on).
    func rank(query: String, in directory: URL, isCurrent: @escaping @MainActor () -> Bool) async
        -> [FileEntry]?
    {
        await ensureIndex(for: directory, isCurrent: isCurrent)
        guard let index = cachedIndex, let entries = cachedEntries, cachedDir == directory else {
            return nil
        }
        let order = await Task.detached { SemanticSearcher.rank(query: query, in: index) }.value
        return order.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    /// Drop the cache (e.g. a preference that affects indexing changed).
    func invalidate() {
        cachedDir = nil
        cachedIndex = nil
        cachedEntries = nil
    }

    /// Enumerate and embed `directory` off the main thread, adopting the result only if
    /// `isCurrent()` still holds (the user hasn't navigated away).
    private func ensureIndex(for directory: URL, isCurrent: @escaping @MainActor () -> Bool) async {
        guard cachedDir != directory || cachedIndex == nil else { return }
        let maxItems = Self.maxItems
        let ocr = includeOCR
        let dirEntries = await Task.detached {
            (try? BulkEnumerator().entries(of: directory, includingHidden: false)) ?? []
        }.value
        let built = await Task.detached {
            SemanticSearcher.index(dirEntries, in: directory, maxItems: maxItems, ocrImages: ocr)
        }.value
        if isCurrent() {
            cachedDir = directory
            cachedEntries = dirEntries
            cachedIndex = built
        }
    }
}
