import Foundation
import Testing

@testable import PathemEngine

@Suite struct SemanticIndexTests {
    /// Deterministic embedder so the ranking logic is tested without the OS model.
    struct StubEmbedder: TextEmbedder {
        let dimension = 3
        let table: [String: [Float]]
        func embed(_ text: String) -> [Float]? { table[text] }
    }

    @Test func cosineIdenticalIsOneOrthogonalIsZero() {
        #expect(abs(SemanticIndex<Int>.cosine([1, 2, 3], [1, 2, 3]) - 1) < 1e-6)
        #expect(abs(SemanticIndex<Int>.cosine([1, 0], [0, 1])) < 1e-6)
    }

    @Test func ranksMostSimilarItemFirst() {
        let stub = StubEmbedder(table: [
            "report": [1, 0, 0],
            "invoice": [0, 1, 0],
            "photo": [0, 0, 1],
            "query": [0.9, 0.1, 0],  // closest to "report"
        ])
        var index = SemanticIndex<String>(embedder: stub)
        index.add("report", text: "report")
        index.add("invoice", text: "invoice")
        index.add("photo", text: "photo")

        let hits = index.search("query", topK: 3)
        #expect(hits.count == 3)
        #expect(hits.first?.id == "report")
    }

    @Test func skipsUnembeddableItems() {
        let stub = StubEmbedder(table: ["a": [1, 0, 0]])
        var index = SemanticIndex<String>(embedder: stub)
        let addedA = index.add("a", text: "a")
        let addedB = index.add("b", text: "b")  // not in table -> nil -> skipped
        #expect(addedA)
        #expect(!addedB)
        #expect(index.count == 1)
    }

    /// Real on-device embeddings. Skips gracefully if the OS model asset isn't
    /// present (so it never flakes in a headless run).
    @Test func nlEmbedderRanksRelatedWordAboveUnrelated() {
        let embedder = NLEmbedder()
        guard embedder.dimension > 0 else { return }  // asset unavailable; skip

        var index = SemanticIndex<String>(embedder: embedder)
        let addedCat = index.add("cat", text: "cat")
        let addedAuto = index.add("automobile", text: "automobile")
        guard addedCat, addedAuto else { return }  // embedding unavailable; skip

        let hits = index.search("kitten", topK: 2)
        let catScore = hits.first { $0.id == "cat" }?.score ?? -1
        let autoScore = hits.first { $0.id == "automobile" }?.score ?? -1
        #expect(catScore > autoScore)
    }
}
