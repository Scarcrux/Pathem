import AppKit
import Photos

/// Thin wrapper over PhotoKit for browsing and exporting the macOS Photos library. Reads through the
/// framework (never the `.photoslibrary` bundle on disk, which is a managed database + originals that
/// direct edits corrupt). Browse + export only for now; edit-back into Photos is a later tier.
/// Nonisolated: PhotoKit fetch/write are thread-safe, so browse runs on the main-actor UI and the
/// file-promise export runs on its background operation queue, both without hopping.
enum PhotoLibrary {
    /// A browsable collection: a user album or a built-in smart album, with a stable identifier and a
    /// live asset count.
    struct Album: Identifiable {
        let id: String  // PHAssetCollection.localIdentifier
        let title: String
        let count: Int
        let collection: PHAssetCollection
    }

    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Request read access (Photos prompts once). Returns the resulting status.
    static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static var isAuthorized: Bool {
        let status = authorizationStatus()
        return status == .authorized || status == .limited
    }

    /// The albums to show, in display order: the key smart albums (All Photos, Favorites, Recents,
    /// Screenshots, Selfies, Videos) that actually contain something, then the user's own albums.
    static func albums() -> [Album] {
        var result: [Album] = []

        let smartSubtypes: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumRecentlyAdded,
            .smartAlbumScreenshots, .smartAlbumSelfPortraits, .smartAlbumVideos,
            .smartAlbumPanoramas, .smartAlbumBursts,
        ]
        for subtype in smartSubtypes {
            let fetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            fetch.enumerateObjects { collection, _, _ in
                if let album = album(from: collection), album.count > 0 { result.append(album) }
            }
        }

        let userOptions = PHFetchOptions()
        userOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: userOptions)
        userAlbums.enumerateObjects { collection, _, _ in
            if let album = album(from: collection), album.count > 0 { result.append(album) }
        }
        return result
    }

    private static func album(from collection: PHAssetCollection) -> Album? {
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        let title = collection.localizedTitle ?? L("photos.untitledAlbum", "Untitled Album")
        return Album(id: collection.localIdentifier, title: title, count: assets.count, collection: collection)
    }

    /// The assets in an album, newest first.
    static func assets(in album: Album) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(in: album.collection, options: options)
    }

    /// The original filename for an asset (from its primary resource), or a fallback of its id + a
    /// guessed extension. Pure enough to reason about; used to name exports.
    static func originalFilename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let primary = primaryResource(resources) { return primary.originalFilename }
        let ext = asset.mediaType == .video ? "mov" : "jpg"
        return "\(asset.localIdentifier.replacingOccurrences(of: "/", with: "_")).\(ext)"
    }

    /// Pick the resource that represents the asset's original file (photo or video), preferring the
    /// full original over edited/alternate resources.
    static func primaryResource(_ resources: [PHAssetResource]) -> PHAssetResource? {
        let preferred: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo, .audio]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    static func asset(withID id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Export an asset's original into `directory` under a non-colliding name; returns the written URL.
    /// Takes the asset's stable id (a Sendable String) so nothing non-Sendable crosses actors.
    static func exportOriginal(assetID: String, to directory: URL) async throws -> URL {
        guard let asset = asset(withID: assetID),
            let resource = primaryResource(PHAssetResource.assetResources(for: asset))
        else { throw ExportError.noResource }
        let destination = uniqueURL(in: directory, name: resource.originalFilename)
        try await writeResource(resource, to: destination)
        return destination
    }

    /// Write an asset's original resource to an EXACT url (used by the drag-out file promise, which
    /// hands us the destination). Fetches from iCloud if the original isn't local.
    static func writeOriginal(assetID: String, to url: URL) async throws {
        guard let asset = asset(withID: assetID),
            let resource = primaryResource(PHAssetResource.assetResources(for: asset))
        else { throw ExportError.noResource }
        try await writeResource(resource, to: url)
    }

    /// Clear the GPS location from the given assets: an edit back into the Photos library via
    /// PHAssetChangeRequest. Metadata only (no pixel change), atomic, and revertible in Photos, so
    /// it's the safe kind of edit-back. Assets without a location are skipped. Takes stable String
    /// ids and re-fetches inside the change block, so no non-Sendable PHAsset crosses an actor.
    static func removeLocation(assetIDs: [String]) async -> (changed: Int, error: String?) {
        let withLocation = assetIDs.filter { asset(withID: $0)?.location != nil }
        guard !withLocation.isEmpty else { return (0, nil) }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                for id in withLocation {
                    guard let asset = asset(withID: id) else { continue }
                    PHAssetChangeRequest(for: asset).location = nil
                }
            } completionHandler: { success, error in
                continuation.resume(returning: (success ? withLocation.count : 0, error?.localizedDescription))
            }
        }
    }

    private static func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    enum ExportError: LocalizedError {
        case noResource
        var errorDescription: String? {
            L("photos.exportNoResource", "This item has no exportable file.")
        }
    }

    /// A non-colliding destination URL: `name`, then `name 2`, `name 3`, … if taken.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
