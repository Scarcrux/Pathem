import Foundation
import Testing

@testable import PathemEngine

/// A deterministic stand-in for the OS embedder so clustering is testable without the
/// NaturalLanguage model asset. Each registered name maps to a fixed vector; names not
/// registered return `nil` (mirroring an un-embeddable token).
private struct StubEmbedder: TextEmbedder {
    let vectors: [String: [Float]]
    var dimension: Int { 3 }
    func embed(_ text: String) -> [Float]? { vectors[text] }
}

@Suite struct SemanticDedupTests {
    private func entry(_ name: String) -> FileEntry {
        FileEntry(name: name, isDirectory: false, size: 1, modificationDate: nil)
    }

    @Test func clustersNamesWithNearIdenticalVectors() {
        // "invoice"/"invoyce" point almost the same way; "budget" is orthogonal.
        let stub = StubEmbedder(vectors: [
            "invoice": [1, 0, 0],
            "invoice-final": [0.99, 0.14, 0],
            "budget": [0, 1, 0],
        ])
        let entries = [entry("invoice.pdf"), entry("invoice-final.pdf"), entry("budget.pdf")]
        let groups = SemanticDedup.similarGroups(entries, embedder: stub, threshold: 0.86)

        #expect(groups.count == 1)
        let names = Set(groups[0].files.map(\.name))
        #expect(names == ["invoice.pdf", "invoice-final.pdf"])
        #expect(!names.contains("budget.pdf"))
    }

    @Test func stripsExtensionBeforeEmbedding() {
        // The keys are the *base* names, proving the extension is stripped first.
        let stub = StubEmbedder(vectors: ["report": [1, 0, 0], "report copy": [0.98, 0.2, 0]])
        let groups = SemanticDedup.similarGroups(
            [entry("report.txt"), entry("report copy.txt")], embedder: stub, threshold: 0.86)
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)
    }

    @Test func dropsUnembeddableNamesInsteadOfGrouping() {
        // "1234" has no vector; it must not be forced into any cluster.
        let stub = StubEmbedder(vectors: ["a": [1, 0, 0], "a-copy": [0.99, 0.1, 0]])
        let entries = [entry("a.txt"), entry("a-copy.txt"), entry("1234.txt")]
        let groups = SemanticDedup.similarGroups(entries, embedder: stub, threshold: 0.86)
        #expect(groups.count == 1)
        #expect(!groups.flatMap { $0.files.map(\.name) }.contains("1234.txt"))
    }

    @Test func skipsDirectories() {
        let stub = StubEmbedder(vectors: ["docs": [1, 0, 0], "docs2": [0.99, 0.1, 0]])
        let entries = [
            FileEntry(name: "docs", isDirectory: true, size: 0, modificationDate: nil),
            FileEntry(name: "docs2", isDirectory: true, size: 0, modificationDate: nil),
        ]
        #expect(SemanticDedup.similarGroups(entries, embedder: stub).isEmpty)
    }

    @Test func mostSimilarGroupComesFirst() {
        // Group A is a tighter cluster (0.999) than group B (0.90); A must sort ahead.
        let stub = StubEmbedder(vectors: [
            "alpha": [1, 0, 0], "alpha2": [0.999, 0.0447, 0],
            "beta": [0, 1, 0], "beta2": [0.30, 0.954, 0],
        ])
        let entries = [entry("alpha.txt"), entry("alpha2.txt"), entry("beta.txt"), entry("beta2.txt")]
        let groups = SemanticDedup.similarGroups(entries, embedder: stub, threshold: 0.86)
        #expect(groups.count == 2)
        #expect(groups[0].similarity > groups[1].similarity)
        #expect(groups[0].files.contains { $0.name == "alpha.txt" })
    }
}
