import Foundation
import Testing

@testable import PathemEngine

@Suite struct SemanticSearcherTests {
    /// A deterministic stand-in for Apple's non-Sendable `NLEmbedding`. It records how many calls
    /// enter `vector(for:)` at once and pauses long enough that an unlocked wrapper reliably
    /// overlaps after the start gate releases every task together.
    private final class OverlapDetectingEmbedding: NLEmbeddingBackend, @unchecked Sendable {
        let dimension = 2
        private let statsLock = NSLock()
        private var activeCalls = 0
        private var highWatermark = 0

        func vector(for string: String) -> [Double]? {
            statsLock.lock()
            activeCalls += 1
            highWatermark = max(highWatermark, activeCalls)
            statsLock.unlock()

            Thread.sleep(forTimeInterval: 0.005)

            statsLock.lock()
            activeCalls -= 1
            statsLock.unlock()
            return [Double(string.count), 1]
        }

        var maximumOverlap: Int {
            statsLock.lock()
            defer { statsLock.unlock() }
            return highWatermark
        }
    }

    private actor StartGate {
        let target: Int
        private var arrivals = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(target: Int) { self.target = target }

        func wait() async {
            arrivals += 1
            if arrivals == target {
                let ready = waiters
                waiters.removeAll()
                for waiter in ready { waiter.resume() }
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @Test func sharedEmbedderSerializesConcurrentFrameworkCalls() async {
        let callCount = 32
        let backend = OverlapDetectingEmbedding()
        let embedder = NLEmbedder(embedding: backend)
        let gate = StartGate(target: callCount)

        let resultCount = await withTaskGroup(of: [Float]?.self, returning: Int.self) { group in
            for i in 0..<callCount {
                group.addTask {
                    await gate.wait()
                    return embedder.embed("query-\(i)")
                }
            }
            var count = 0
            for await result in group where result != nil { count += 1 }
            return count
        }

        #expect(resultCount == callCount)
        #expect(backend.maximumOverlap == 1)
    }

    /// Content-aware ranking: files with neutral NAMES ("a.txt"/"b.txt") but
    /// distinguishing CONTENTS should rank by meaning of the content. Skips
    /// gracefully if the on-device model asset isn't present.
    @Test func ranksByContentNotJustName() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-search-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "cats kittens felines pets purring".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "automobiles engines cars vehicles driving".write(
            to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let entries = (try? BulkEnumerator().entries(of: dir, includingHidden: false)) ?? []
        let index = SemanticSearcher.index(entries, in: dir)
        guard !index.isEmpty else { return }  // model asset unavailable; skip

        let order = SemanticSearcher.rank(query: "kitten", in: index)
        let ranked = order.compactMap { $0 < entries.count ? entries[$0].name : nil }
        // Required, not conditional: once the model is present both files must rank,
        // so a regression that drops one fails loudly instead of passing vacuously.
        let aPos = try #require(ranked.firstIndex(of: "a.txt"))
        let bPos = try #require(ranked.firstIndex(of: "b.txt"))
        #expect(aPos < bPos)  // the cat-content file ranks above the car-content file
    }

    /// A toy embedder so the index/rank pipeline is asserted deterministically,
    /// independent of whether the on-device NL model asset is present.
    private struct StubEmbedder: TextEmbedder {
        var dimension: Int { 2 }
        func embed(_ text: String) -> [Float]? {
            let lower = text.lowercased()
            let cat: Float = (lower.contains("cat") || lower.contains("kitten")) ? 1 : 0
            let car: Float = (lower.contains("car") || lower.contains("engine")) ? 1 : 0
            return [cat, car]
        }
    }

    @Test func rankAndIndexAreContentAwareWithInjectedEmbedder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "pathem-stubsearch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "cat kitten purring".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "car engine driving".write(
            to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let entries = (try? BulkEnumerator().entries(of: dir, includingHidden: false)) ?? []
        let stub = StubEmbedder()
        let index = SemanticSearcher.index(entries, in: dir, embedder: stub)
        #expect(!index.isEmpty)  // always builds with the stub (dimension > 0)

        let order = SemanticSearcher.rank(query: "kitten", in: index, embedder: stub)
        let ranked = order.compactMap { $0 < entries.count ? entries[$0].name : nil }
        #expect(ranked.first == "a.txt")  // cat-content ranks above car-content for "kitten"
    }

    @Test func datalessEntryIsIndexedByNameOnly() throws {
        // A dataless cloud placeholder must NOT have its contents read (that would
        // trigger a download); only its name is embedded.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "pathem-dataless-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "car engine driving".write(
            to: dir.appendingPathComponent("kitten.txt"), atomically: true, encoding: .utf8)

        let regular = FileEntry(
            name: "kitten.txt", isDirectory: false, size: 0, modificationDate: nil)
        let dataless = FileEntry(
            name: "kitten.txt", isDirectory: false, size: 0, modificationDate: nil, isDataless: true
        )
        let index = SemanticSearcher.index([regular, dataless], in: dir, embedder: StubEmbedder())

        #expect(index.vectors.count == 2)
        #expect(index.vectors[0] == [1, 1])  // regular: name "kitten" + content "car"
        #expect(index.vectors[1] == [1, 0])  // dataless: name only, content never read
    }

    /// Records what each embedded text contained, standing in for the on-device model.
    private final class RecordingEmbedder: TextEmbedder, @unchecked Sendable {
        let dimension = 1
        private let lock = NSLock()
        private(set) var texts: [String] = []
        func embed(_ text: String) -> [Float]? {
            lock.withLock { texts.append(text) }
            return [1]
        }
    }

    /// A recursive (flattened) entry lives in its own folder, not in the folder searched: its
    /// content snippet must be read from there.
    @Test func indexReadsAFlattenedEntryFromItsOwnFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-sem-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "deep marker words".write(
            to: sub.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let flat = FlatEnumerator.entries(of: root, includeFolders: false).entries
        #expect(flat.map(\.name) == ["note.txt"])
        let embedder = RecordingEmbedder()
        let index = SemanticSearcher.index(flat, in: root, embedder: embedder)
        #expect(index.ids == [0])
        #expect(embedder.texts.first?.contains("deep marker words") == true)
    }
}
