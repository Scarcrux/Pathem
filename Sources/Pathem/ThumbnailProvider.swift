import AppKit
import QuickLookThumbnailing

/// Produces QuickLook content thumbnails (image/PDF/video/app previews) for the icon
/// and gallery grids, cached and generated off the main thread. Falls back to the
/// caller's type icon until a thumbnail arrives. Keyed by path + size only, so the
/// scroll hot path never stats the file; a negative cache stops files with no preview
/// from being re-requested on every scroll. Online-only (dataless) files are never
/// passed here, so a request can't fault a download.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private let noPreview = NSCache<NSString, NSNumber>()  // negative cache, bounded
    /// Keys we've populated, so `evict(_:)` can drop every size for a file (NSCache can't
    /// enumerate). Bounded implicitly by the same churn that bounds the caches.
    private var liveKeys: Set<String> = []
    private init() {
        cache.countLimit = 4000
        noPreview.countLimit = 8000
    }

    /// Drop every cached size (and the negative-cache entry) for a file whose pixels changed on
    /// disk (e.g. after a rotate), so the grids regenerate its thumbnail instead of showing stale.
    func evict(_ url: URL) {
        let prefix = url.path + "|"
        let stale = liveKeys.filter { $0.hasPrefix(prefix) }
        for key in stale {
            cache.removeObject(forKey: key as NSString)
            noPreview.removeObject(forKey: key as NSString)
            liveKeys.remove(key)
        }
    }

    private func key(_ url: URL, _ size: CGSize) -> String {
        "\(url.path)|\(Int(size.width))x\(Int(size.height))"
    }

    /// A cached thumbnail if one was already generated for this url/size.
    func cached(_ url: URL, size: CGSize) -> NSImage? {
        cache.object(forKey: key(url, size) as NSString)
    }

    /// Generate a thumbnail off the main thread; `completion` runs on the main actor
    /// only if a representation is produced (callers guard against cell reuse).
    func generate(_ url: URL, size: CGSize, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        let cacheKey = key(url, size)
        if let hit = cache.object(forKey: cacheKey as NSString) {
            completion(hit)
            return
        }
        if noPreview.object(forKey: cacheKey as NSString) != nil { return }  // known: no preview
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else {
                // Remember there's no preview so we don't re-request it on every scroll.
                Task { @MainActor in
                    self?.noPreview.setObject(1, forKey: cacheKey as NSString)
                    self?.liveKeys.insert(cacheKey)
                }
                return
            }
            // QuickLook calls back off the main actor; box the non-Sendable image +
            // completion (and capture the key as a Sendable String) to cross back.
            let result = Delivery(image: representation.nsImage, key: cacheKey, completion: completion)
            Task { @MainActor in
                self?.cache.setObject(result.image, forKey: result.key as NSString)
                self?.liveKeys.insert(result.key)
                result.completion(result.image)
            }
        }
    }

    /// Carries the (non-Sendable) thumbnail and main-actor completion from QuickLook's
    /// callback queue back to the main actor. Safe because every field is only ever
    /// touched on the main actor.
    private struct Delivery: @unchecked Sendable {
        let image: NSImage
        let key: String
        let completion: (NSImage) -> Void
    }
}
