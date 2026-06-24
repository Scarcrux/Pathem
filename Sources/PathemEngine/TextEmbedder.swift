import Foundation
import NaturalLanguage

/// Produces a fixed-length vector for a piece of text.
///
/// This is the seam the AI search is built on (DESIGN.md §2): the index talks
/// only to this protocol, so the backend can be swapped — Apple's
/// NaturalLanguage now; a bundled `bge-small` or `NLContextualEmbedding` later —
/// without touching anything above it. All of these are on-device and free.
public protocol TextEmbedder {
    /// Vector length, or `0` if the embedder is unavailable (e.g. the OS model
    /// asset hasn't downloaded yet).
    var dimension: Int { get }
    /// Embed `text`, or `nil` if it can't be embedded.
    func embed(_ text: String) -> [Float]?
}

/// On-device, free sentence embeddings via Apple's NaturalLanguage framework.
/// Runs on every Mac (including Intel), needs no Apple Intelligence, and bundles
/// nothing — the model is an on-demand OS asset. This is the universal default
/// that keeps semantic search free for everyone.
public struct NLEmbedder: TextEmbedder {
    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    public var dimension: Int { embedding?.dimension ?? 0 }

    public func embed(_ text: String) -> [Float]? {
        guard let embedding, let vector = embedding.vector(for: text) else { return nil }
        return vector.map(Float.init)
    }

    /// A process-wide embedder so the on-device model asset loads once and is
    /// reused. The underlying NLEmbedding is read-only and safe to share across
    /// threads; `nonisolated(unsafe)` opts this immutable value out of the Sendable
    /// check without locking.
    nonisolated(unsafe) public static let shared = NLEmbedder()
}
