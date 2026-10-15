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
    /// One policy for all folder drop targets. Command inverts the user's default;
    /// never advertise or perform a move the drag source did not offer.
    @MainActor
    static func operation(
        for info: NSDraggingInfo, movesByDefault: Bool
    ) -> NSDragOperation {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let wantsMove = movesByDefault != flags.contains(.command)
        if wantsMove && info.draggingSourceOperationMask.contains(.move) { return .move }
        return info.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    /// The deprecated-but-still-widely-read filenames type. Modern apps take `public.file-url`
    /// (which our per-item pasteboard writers already provide), but cross-platform / older apps
    /// (e.g. VMware Fusion, some Java and Electron apps) only look for `NSFilenamesPboardType`
    /// in the pasteboard's advertised types, so we add it too when a drag begins.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// A pasteboard writer for one dragged file: a file promise (browsers, sandboxed apps)
    /// that also carries the file URL (in-app drops, Finder). Use from `pasteboardWriterForRow`
    /// / `pasteboardWriterForItemAt`.
    static func item(for url: URL) -> NSPasteboardWriting {
        // A directory (folder or package) is dragged as a plain file URL, with NO promise. A promise
        // for a folder is worse than useless: browser upload zones and sandboxed drops can't take a
        // directory anyway, while its presence makes Finder pull the promise and land a truncated
        // stub instead of copying the whole tree from the file URL. The file URL is exactly what
        // Finder and in-app drops want for a recursive copy.
        // Directories drag as a plain file URL (no promise). So do text-like files (HTML, plain
        // text, source, RTF): the mere presence of a file promise makes Messages / Mail pull it,
        // read the file, and INSERT its text inline instead of attaching it. A plain file URL is
        // exactly what Finder drags, and it attaches correctly. (Trade-off: those types can no
        // longer be dropped into a browser upload zone, which needs the promise.)
        if isDirectory(url) || isTextLike(url) {
            return url as NSURL
        }
        let item = FileDragItem(
            fileType: contentType(of: url).identifier, delegate: FilePromiseFulfiller.shared)
        item.sourceURL = url
        // userInfo is what survives when Foundation rebuilds the provider for file-provider XPC
        // fulfillment (Messages); the delegate reads the source from here. See source(from:).
        item.userInfo = url
        return item
    }

    /// Whether `url` is a directory (a plain folder or a package/bundle), so it should drag as a
    /// file URL rather than a file promise.
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Whether `url` is a text-like file (HTML, plain text, source code, RTF, JSON, CSV, XML) that
    /// should drag WITHOUT a file promise, so Messages / Mail attach the file instead of inlining
    /// its text. Image formats are excluded even when XML-based (e.g. SVG), so they keep the promise
    /// and still work in browser upload zones.
    static func isTextLike(_ url: URL) -> Bool {
        let type = contentType(of: url)
        guard !type.conforms(to: .image) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .html) || type.conforms(to: .rtf)
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

    /// Read the dragged file URLs from a drop, tolerant of how the source wrote them. Modern
    /// per-item `public.file-url` is preferred, but that read intermittently comes back empty when
    /// a drag also carries a promise + the legacy filenames list (the pasteboard-level
    /// `setPropertyList` can shadow the per-item URL reps), so fall back to the legacy filenames.
    /// This is what makes an in-app pane-to-pane drop reliable.
    static func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            return urls
        }
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty
        {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return nil
    }

    /// Whether a drop carries file URLs (modern or legacy). For validateDrop's can-accept check.
    static func hasFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || (pasteboard.propertyList(forType: filenamesType) as? [String])?.isEmpty == false
    }
}
