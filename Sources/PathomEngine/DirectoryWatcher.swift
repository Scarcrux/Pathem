import CoreServices
import Foundation

/// Watches a directory for on-disk changes via FSEvents and fires a callback
/// (on a private serial queue) when something changes. Used to keep a pane's
/// listing live and to invalidate / refresh the semantic-search index.
///
/// This wraps a C API with an `Unmanaged` self pointer and a `@convention(c)`
/// callback. The owner must keep the watcher alive for as long as it should
/// fire; `stop()` (also called from `deinit`) tears the stream down.
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef? = nil
    private let queue = DispatchQueue(label: "ai.scarcrux.pathom.DirectoryWatcher")
    private let onChange: @Sendable () -> Void

    /// Creates and starts a watcher for `path`. Returns `nil` if the stream
    /// can't be created. `onChange` runs on a private serial queue (events are
    /// coalesced within `latency`); hop to your actor inside it.
    public init?(
        path: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags)
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        // Already on the watcher's dispatch queue (set via FSEventStreamSetDispatchQueue).
        Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
    }
}
