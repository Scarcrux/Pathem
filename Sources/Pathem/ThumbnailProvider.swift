import AppKit
import QuickLookThumbnailing

/// Produces QuickLook content thumbnails (image/PDF/video/app previews) for the
/// icon and gallery grids, cached and generated off the main thread. Falls back to
/// the caller's type icon until a thumbnail arrives, and is keyed by path + size +
/// modification time so an edited file refreshes. Online-only (dataless) files are
/// never passed here, so requesting a thumbnail can't silently fault a download.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 4000 }

    private func key(_ url: URL, _ size: CGSize) -> NSString {
        let mtime =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(Int(size.width))x\(Int(size.height))|\(mtime)" as NSString
    }

    /// A cached thumbnail if one was already generated for this exact url/size/mtime.
    func cached(_ url: URL, size: CGSize) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    /// Generate a thumbnail off the main thread; `completion` runs on the main actor
    /// only if a representation is produced (callers guard against cell reuse).
    func generate(_ url: URL, size: CGSize, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        let cacheKey = key(url, size)
        if let hit = cache.object(forKey: cacheKey) {
            completion(hit)
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else { return }  // no preview available: keep the type icon
            // QuickLook calls back off the main actor; box the non-Sendable values so
            // they can cross back to the main actor, where AppKit requires them.
            let result = Delivery(image: representation.nsImage, key: cacheKey, completion: completion)
            Task { @MainActor in
                self?.cache.setObject(result.image, forKey: result.key)
                result.completion(result.image)
            }
        }
    }

    /// Carries the (non-Sendable) thumbnail, cache key, and main-actor completion
    /// from QuickLook's callback queue back to the main actor. Safe because every
    /// field is only ever touched on the main actor.
    private struct Delivery: @unchecked Sendable {
        let image: NSImage
        let key: NSString
        let completion: (NSImage) -> Void
    }
}
