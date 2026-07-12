import Foundation

/// A cached, content-aware semantic index for one folder: entry indices paired
/// with their embedding vectors. `Sendable` so it can be built off the main
/// thread and cached by the UI (the embedder itself never crosses the boundary).
public struct FolderSemanticIndex: Sendable {
    public let ids: [Int]
    public let vectors: [[Float]]
    public var isEmpty: Bool { ids.isEmpty }

    public init(ids: [Int], vectors: [[Float]]) {
        self.ids = ids
        self.vectors = vectors
    }
}

/// Builds and queries content-aware semantic indexes for a folder.
///
/// Both calls construct their own embedder and are synchronous — run them off
/// the main thread (the UI does this via `Task.detached`). `index` is the
/// expensive step (reads + embeds file contents) and is meant to be cached;
/// `rank` is one query embedding + a cosine sweep.
public enum SemanticSearcher {
    /// Build an index over `entries` in `directory`, embedding each item's name
    /// plus a content snippet (for text-like files). Capped at `maxItems`.
    /// Returns an empty index if the on-device model asset isn't ready.
    public static func index(
        _ entries: [FileEntry], in directory: URL, maxItems: Int = 5000, ocrImages: Bool = false,
        pdf: PDFTextExtracting? = nil, embedder: TextEmbedder = NLEmbedder()
    ) -> FolderSemanticIndex {
        guard embedder.dimension > 0 else { return FolderSemanticIndex(ids: [], vectors: []) }

        var ids: [Int] = []
        var vectors: [[Float]] = []
        for (i, entry) in entries.prefix(maxItems).enumerated() {
            var text = entry.name
            // Never read a dataless cloud placeholder: indexing its contents would
            // silently trigger a download. Index its name only.
            if !entry.isDirectory, !entry.isDataless,
                let snippet = ContentExtractor.snippet(
                    of: directory.appendingPathComponent(entry.name), ocr: ocrImages, pdf: pdf)
            {
                text += "\n" + snippet
            }
            if let vector = embedder.embed(text) {
                ids.append(i)
                vectors.append(vector)
            }
        }
        return FolderSemanticIndex(ids: ids, vectors: vectors)
    }

    /// Rank the indexed items by cosine similarity to `query`, best first.
    /// Returns the original entry indices (so the caller maps back to entries).
    public static func rank(
        query: String, in index: FolderSemanticIndex, embedder: TextEmbedder = NLEmbedder()
    ) -> [Int] {
        guard !index.isEmpty else { return [] }
        guard let q = embedder.embed(query) else { return index.ids }
        let scored = zip(index.ids, index.vectors).map { ($0.0, SemanticIndex<Int>.cosine(q, $0.1)) }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
