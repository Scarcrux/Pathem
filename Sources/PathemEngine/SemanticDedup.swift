import Foundation

/// Groups files whose *names* are semantically similar, using the on-device text
/// embedder. DuplicateFinder catches byte-identical copies; this catches the other
/// kind of clutter — "invoice-final.pdf" / "invoice final (2).pdf" / "Invoice FINAL
/// v3.pdf", "IMG_2013.jpg" vs "IMG_2013 copy.jpg", "notes.md" vs "meeting notes.md".
/// Pure over its inputs (the embedder is injected), so it's unit-tested with a
/// deterministic stub; callers run it off the main thread against `NLEmbedder.shared`.
public enum SemanticDedup {
    public struct Group: Sendable, Equatable {
        /// Members ordered as encountered; `[0]` is the cluster seed.
        public let files: [FileEntry]
        /// Lowest pairwise similarity kept in the cluster (seed vs. each member), 0…1.
        public let similarity: Float
        public init(files: [FileEntry], similarity: Float) {
            self.files = files
            self.similarity = similarity
        }
    }

    /// Cluster `entries` (directories skipped) by embedding each file's *base name*
    /// (extension stripped) and greedily grouping names whose cosine similarity is at
    /// least `threshold`. Only clusters of 2+ are returned, most-similar first. Names
    /// the embedder can't vectorize (e.g. pure numbers/symbols) are dropped, not grouped.
    public static func similarGroups(
        _ entries: [FileEntry], embedder: TextEmbedder = NLEmbedder.shared,
        threshold: Float = 0.86, maxItems: Int = 5_000
    ) -> [Group] {
        let files = entries.filter { !$0.isDirectory }.prefix(maxItems)
        var vectors: [(entry: FileEntry, vec: [Float])] = []
        vectors.reserveCapacity(files.count)
        for entry in files {
            let base = (entry.name as NSString).deletingPathExtension
            let text = base.isEmpty ? entry.name : base
            guard let vec = embedder.embed(text), let normalized = unit(vec) else { continue }
            vectors.append((entry, normalized))
        }

        var used = Set<Int>()
        var groups: [Group] = []
        for i in vectors.indices where !used.contains(i) {
            var members = [vectors[i].entry]
            var minSim: Float = 1
            for j in (i + 1)..<vectors.count where !used.contains(j) {
                let sim = dot(vectors[i].vec, vectors[j].vec)
                if sim >= threshold {
                    members.append(vectors[j].entry)
                    used.insert(j)
                    minSim = Swift.min(minSim, sim)
                }
            }
            if members.count > 1 {
                used.insert(i)
                groups.append(Group(files: members, similarity: minSim))
            }
        }
        return groups.sorted { $0.similarity > $1.similarity }
    }

    /// Normalize to unit length so cosine similarity is a plain dot product; returns
    /// `nil` for a zero (or dimensionless) vector, which can't be a meaningful match.
    private static func unit(_ v: [Float]) -> [Float]? {
        var sum: Float = 0
        for x in v { sum += x * x }
        let mag = sum.squareRoot()
        guard mag > 0 else { return nil }
        return v.map { $0 / mag }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = Swift.min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<n { sum += a[i] * b[i] }
        return sum
    }
}
