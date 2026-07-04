import AppKit
import UniformTypeIdentifiers

/// A dragged file that advertises BOTH a plain file URL and a file promise. The file URL
/// satisfies in-app drops and Finder (which read `public.file-url`); the promise satisfies
/// targets that only take promised files, most importantly web upload drop zones in a
/// browser (Chrome/Safari materialize the promise into `DataTransfer.files`) and sandboxed
/// apps. Finder drags this same way; providing only a file URL is why a drag into a browser
/// upload area does nothing.
final class FileDragItem: NSFilePromiseProvider {
    var sourceURL: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.fileURL]
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        type == .fileURL ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let sourceURL {
            return (sourceURL as NSURL).pasteboardPropertyList(forType: .fileURL)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Fulfills a file promise by copying the source file to wherever the receiver asks (a
/// location it owns). One shared instance serves every draggable view. Copies run on a
/// background queue so a large file doesn't block the drop.
final class FilePromiseFulfiller: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = FilePromiseFulfiller()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        (provider as? FileDragItem)?.sourceURL?.lastPathComponent ?? "file"
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo destination: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let source = (provider as? FileDragItem)?.sourceURL else {
            completionHandler(nil)
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
}

/// Shared helpers for dragging files out to other apps.
enum FileDrag {
    /// The deprecated-but-still-widely-read filenames type. Modern apps take `public.file-url`
    /// (which our per-item pasteboard writers already provide), but cross-platform / older apps
    /// (e.g. VMware Fusion, some Java and Electron apps) only look for `NSFilenamesPboardType`
    /// in the pasteboard's advertised types, so we add it too when a drag begins.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// A pasteboard writer for one dragged file: a file promise (browsers, sandboxed apps)
    /// that also carries the file URL (in-app drops, Finder). Use from `pasteboardWriterForRow`
    /// / `pasteboardWriterForItemAt`.
    static func item(for url: URL) -> NSPasteboardWriting {
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let item = FileDragItem(fileType: type, delegate: FilePromiseFulfiller.shared)
        item.sourceURL = url
        return item
    }

    /// Advertise the dragged files under the legacy filenames type, alongside the per-item
    /// file URLs already on the pasteboard. Call from a drag session's willBegin hook.
    static func addLegacyFilenames(_ urls: [URL], to pasteboard: NSPasteboard) {
        let paths = urls.filter { $0.isFileURL }.map(\.path)
        guard !paths.isEmpty else { return }
        pasteboard.addTypes([filenamesType], owner: nil)
        pasteboard.setPropertyList(paths, forType: filenamesType)
    }
}
