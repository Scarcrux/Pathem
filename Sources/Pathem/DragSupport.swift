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

    /// The source file for a promise. Read from `userInfo`, NOT from a FileDragItem cast:
    /// when another app pulls the promise through file-provider XPC (Messages), Foundation
    /// hands the delegate a fresh NSFilePromiseProvider it built itself, not our subclass, so
    /// `provider as? FileDragItem` is nil there. `userInfo` is the documented channel that
    /// survives that reconstruction; the subclass `sourceURL` is only a fallback.
    private nonisolated static func source(from provider: NSFilePromiseProvider) -> URL? {
        (provider.userInfo as? URL) ?? (provider as? FileDragItem)?.sourceURL
    }

    // These three are marked `nonisolated` on purpose. `NSFilePromiseProviderDelegate` is
    // @MainActor in the SDK, but Foundation actually invokes them OFF the main thread when
    // another app pulls the promise through file-provider XPC (Messages does this on the
    // com.apple.FileCoordination queue). Left main-actor-isolated, Swift's runtime executor
    // check traps (EXC_BREAKPOINT) the moment that happens. The bodies only touch immutable
    // state (a set-once source, the shared queue) and copy a file, so running off-main is
    // safe -- which is what `@unchecked Sendable` above asserts.
    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        Self.source(from: provider)?.lastPathComponent ?? "file"
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo destination: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let source = Self.source(from: provider) else {
            completionHandler(CocoaError(.fileNoSuchFile))  // signal failure, don't "succeed" empty
            return
        }
        do {
            // A receiver may pre-create an empty placeholder at the destination; replacing it
            // (rather than letting copyItem throw "file exists") is what makes the drop land.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
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
        let item = FileDragItem(fileType: contentType(of: url).identifier, delegate: FilePromiseFulfiller.shared)
        item.sourceURL = url
        // userInfo is what survives when Foundation rebuilds the provider for file-provider XPC
        // fulfillment (Messages); the delegate reads the source from here. See source(from:).
        item.userInfo = url
        return item
    }

    /// The file's real Uniform Type, so the promised drop advertises an accurate type (and
    /// MIME, where one exists) rather than a generic blob. Prefer the type the file system
    /// resolves (which honors the actual file, not just its extension), then the extension,
    /// then a plain-data fallback.
    static func contentType(of url: URL) -> UTType {
        if let resolved = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return resolved
        }
        return UTType(filenameExtension: url.pathExtension) ?? .data
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
