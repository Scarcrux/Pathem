import AppKit
import PathemEngine

/// Selected-key metadata work belongs to the listing worker, never a comparison or drawing call.
enum ListingViewMetadata {
    nonisolated static func enrich(
        _ entries: [FileEntry], directory: URL?, format: ViewFormat,
        allowEntryLocations: Bool = true
    ) -> [FileEntry] {
        FileViewMetadata.enrich(
            entries, directory: directory, requirements: format.metadataRequirements,
            allowEntryLocations: allowEntryLocations,
            applicationName: { url in
                guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                    return nil
                }
                return (try? app.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                    ?? app.deletingPathExtension().lastPathComponent
            })
    }
}
