import AppKit

/// Shared helpers for dragging files out to other apps.
enum FileDrag {
    /// The deprecated-but-still-widely-read filenames type. Modern apps take `public.file-url`
    /// (which our per-item pasteboard writers already provide), but cross-platform / older apps
    /// (e.g. VMware Fusion, some Java and Electron apps) only look for `NSFilenamesPboardType`
    /// in the pasteboard's advertised types, so we add it too when a drag begins.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Advertise the dragged files under the legacy filenames type, alongside the per-item
    /// file URLs already on the pasteboard. Call from a drag session's willBegin hook.
    static func addLegacyFilenames(_ urls: [URL], to pasteboard: NSPasteboard) {
        let paths = urls.filter { $0.isFileURL }.map(\.path)
        guard !paths.isEmpty else { return }
        pasteboard.addTypes([filenamesType], owner: nil)
        pasteboard.setPropertyList(paths, forType: filenamesType)
    }
}
