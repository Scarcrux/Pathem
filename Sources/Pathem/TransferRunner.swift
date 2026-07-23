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
        // it), then poll progress, deriving a steady transfer speed + ETA, until the worker
        // finishes and cancels us. The bar tracks bytes every tick; the speed/ETA readout is
        // averaged over a ~1.5s rolling window and refreshed only ~twice a second, so it does
        // not jump around with copyfile's bursty (buffer-flush) writes.
        let monitor = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.progress.begin(verb: verb, over: window) { state.cancel() }
            var samples: [(time: Date, bytes: Int64)] = []
            var lastReadoutRefresh = Date.distantPast
            var shownSpeed = 0.0  // held steady between refreshes so the ETA counts down smoothly
            while !Task.isCancelled {
                let progress = state.progress
                let now = Date()
                samples.append((now, progress.completedBytes))
                while samples.count > 1, now.timeIntervalSince(samples[0].time) > 1.5 {
                    samples.removeFirst()  // keep a ~1.5s window
                }
                // Recompute the speed at most ~2x/sec, as an average over the whole window, once
                // there is enough history to trust it. Until then, show bytes only (no wild guess).
                if now.timeIntervalSince(lastReadoutRefresh) >= 0.5, let first = samples.first {
                    let dt = now.timeIntervalSince(first.time)
                    if dt >= 0.4 { shownSpeed = Double(progress.completedBytes - first.bytes) / dt }
                    lastReadoutRefresh = now
                }
                self.progress.update(progress, bytesPerSecond: max(0, shownSpeed))
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
