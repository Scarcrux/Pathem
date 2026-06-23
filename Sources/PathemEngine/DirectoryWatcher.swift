import CoreServices
import Foundation

/// Watches a directory for on-disk changes via FSEvents and fires a callback
/// (on a private serial queue) when something changes. Used to keep a pane's
/// listing live and to refresh the semantic-search index.
///
/// Lifetime is tied to the stream: the FSEvents context holds a +1 on this
/// object (released in the context's release callback), so the C callback can
/// never reference a freed instance. Teardown runs on the stream's own serial
/// queue, so it serializes behind any in-flight callback.
///
/// Because the stream holds that reference, the watcher does not deallocate
/// until `stop()` is called, so the owner must call it when done. There is
/// intentionally no `deinit` auto-stop: the context release can run on the
/// stream's own queue, where a synchronous teardown would re-enter and trap.
/// Do not call `stop()` from inside the change callback.
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef? = nil
    private let queue = DispatchQueue(label: "com.scarcrux.pathem.DirectoryWatcher")
    private let onChange: @Sendable () -> Void

    /// Creates and starts a watcher for `path`. Returns `nil` if the stream
    /// can't be created. `onChange` runs on a private serial queue (events are
    /// coalesced within `latency`); hop to your actor inside it.
    public init?(
        path: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange

        // FSEvents needs the canonical path (e.g. /var -> /private/var); an
        // unresolved symlink can make it silently drop all events for the folder.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        // The stream owns a +1 on self; the release callback drops it when the
        // stream is torn down. This keeps self alive for the callback's lifetime.
        context.info = Unmanaged.passRetained(self).toOpaque()
        context.release = { rawInfo in
            guard let rawInfo else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(rawInfo).release()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, Self.callback, &context,
                [resolved] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            // Creation failed, so the release callback won't run: balance the +1.
            if let info = context.info { Unmanaged<DirectoryWatcher>.fromOpaque(info).release() }
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stop and tear down the stream. Idempotent. Runs on the stream's serial
    /// queue so it serializes behind any in-flight callback (no use-after-free,
    /// no callback after stop). Must not be called from inside `onChange`.
    public func stop() {
        queue.sync {
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)  // triggers context.release, dropping the +1 on self
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        // On the watcher's serial queue; the stream's +1 keeps self alive.
        Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
    }
}
