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

/// The small slice of `NLEmbedding` that `NLEmbedder` needs. Keeping this as an internal seam lets
/// the concurrency regression test use an overlap-detecting backend instead of depending on an OS
/// model asset or trying to make a process crash probabilistically.
protocol NLEmbeddingBackend: AnyObject {
    var dimension: Int { get }
    func vector(for string: String) -> [Double]?
}

extension NLEmbedding: NLEmbeddingBackend {}

/// `NLEmbedding` does not document concurrent-use safety and is not `Sendable`. Rapid live-search
/// requests can reach the shared embedder from multiple detached tasks, so every backend access
/// must pass through this one lock. The reference state means copies of `NLEmbedder.shared` retain
/// the same lock as well as the same underlying embedding.
private final class LockedNLEmbeddingState: @unchecked Sendable {
    private let embedding: (any NLEmbeddingBackend)?
    private let lock = NSLock()

    init(embedding: (any NLEmbeddingBackend)?) {
        self.embedding = embedding
    }

    var dimension: Int {
        lock.lock()
        defer { lock.unlock() }
        return embedding?.dimension ?? 0
    }

    func vector(for text: String) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        return embedding?.vector(for: text)
    }
}

/// On-device, free sentence embeddings via Apple's NaturalLanguage framework.
/// Runs on every Mac (including Intel), needs no Apple Intelligence, and bundles
/// nothing — the model is an on-demand OS asset. This is the universal default
/// that keeps semantic search free for everyone.
public struct NLEmbedder: TextEmbedder, Sendable {
    private let state: LockedNLEmbeddingState

    public init(language: NLLanguage = .english) {
        self.state = LockedNLEmbeddingState(
            embedding: NLEmbedding.sentenceEmbedding(for: language))
    }

    init(embedding: (any NLEmbeddingBackend)?) {
        self.state = LockedNLEmbeddingState(embedding: embedding)
    }

    public var dimension: Int { state.dimension }

    public func embed(_ text: String) -> [Float]? {
        guard let vector = state.vector(for: text) else { return nil }
        return vector.map(Float.init)
    }

    /// A process-wide embedder so the on-device model asset loads once and is
    /// reused. `LockedNLEmbeddingState` serializes the framework calls made by all
    /// copies, rather than asserting undocumented thread safety.
    public static let shared = NLEmbedder()
}
