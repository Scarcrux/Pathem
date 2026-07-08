import AppKit
import PathemEngine

/// Runs a local copy/move off the main thread with a deferred progress sheet (speed + ETA,
/// cancellable), and hands back the outcome. Owns the progress sheet and its polling monitor
/// -- orchestration that used to sit inline on BrowserViewController. The browser keeps the
/// one-at-a-time gate and the post-transfer bookkeeping (undo, reload); this owns the
/// mechanics of running one and showing its progress.
@MainActor
final class TransferRunner {
    private let progress = TransferProgress()

    /// Copy or move `urls` into `destination`. The sheet appears only after 0.25s, so quick
    /// operations never flash it. `completion` is called on the main actor with the outcome.
    func run(
        urls: [URL], into destination: URL, move: Bool,
        resolution: FileOperations.ConflictResolution, verify: Bool = false, over window: NSWindow?,
        completion: @escaping (FileOperations.Outcome) -> Void
    ) {
        let verb = move ? L("bvc.moving", "Moving") : L("bvc.copying", "Copying")
        let state = TransferState()

        // Main-actor monitor: wait 0.25s before showing the sheet (so quick ops never flash
        // it), then poll progress, deriving a smoothed transfer speed and ETA, until the
        // worker finishes and cancels us.
        let monitor = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.progress.begin(verb: verb, over: window) { state.cancel() }
            var lastSample = Date()
            var lastBytes: Int64 = 0
            var speed = 0.0  // bytes/sec, exponentially smoothed
            while !Task.isCancelled {
                let progress = state.progress
                let now = Date()
                let dt = now.timeIntervalSince(lastSample)
                if dt >= 0.2 {
                    let instant = Double(progress.completedBytes - lastBytes) / dt
                    speed = speed == 0 ? instant : speed * 0.6 + instant * 0.4
                    lastSample = now
                    lastBytes = progress.completedBytes
                }
                self.progress.update(progress, bytesPerSecond: max(0, speed))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> FileOperations.Outcome in
                if move {
                    return FileOperations.move(
                        urls: urls, into: destination, onConflict: resolution,
                        shouldCancel: { state.isCancelled }, report: { state.setProgress($0) })
                }
                return FileOperations.copy(
                    urls: urls, into: destination, onConflict: resolution, verify: verify,
                    shouldCancel: { state.isCancelled }, report: { state.setProgress($0) })
            }.value
            monitor.cancel()
            self?.progress.end()
            completion(outcome)
        }
    }
}
