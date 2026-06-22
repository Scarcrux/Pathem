import Foundation

/// A tiny in-memory semantic index: embed a set of items, then rank them by
/// cosine similarity to a query embedding.
///
/// Brute-force, which is fine at a directory's scale (the `sqlite-vec` / HNSW
/// backend in DESIGN.md is the path for whole-disk, million-vector indexes).
/// The index is generic over an item `ID` so callers can map hits back to
/// whatever they indexed (a file name, an index, a URL).
public struct SemanticIndex<ID: Hashable> {
    public struct Hit: Equatable {
        public let id: ID
        public let score: Float
    }

    private var ids: [ID] = []
    private var vectors: [[Float]] = []
    private let embedder: TextEmbedder

    public init(embedder: TextEmbedder) { self.embedder = embedder }

    public var count: Int { ids.count }

    /// Whether the underlying embedder is ready (its model asset is present).
    public var isUsable: Bool { embedder.dimension > 0 }

    /// Embed and add an item. Returns `false` (and skips it) if the embedder
    /// can't embed the text.
    @discardableResult
    public mutating func add(_ id: ID, text: String) -> Bool {
        guard let vector = embedder.embed(text) else { return false }
        ids.append(id)
        vectors.append(vector)
        return true
    }

    /// The top-`k` items by cosine similarity to `query`, highest first.
    public func search(_ query: String, topK: Int = 20) -> [Hit] {
        guard let q = embedder.embed(query) else { return [] }
        let scored = zip(ids, vectors).map { Hit(id: $0.0, score: Self.cosine(q, $0.1)) }
        return Array(scored.sorted { $0.score > $1.score }.prefix(topK))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
