import AppKit

/// Spring-loaded folders: while a drag dwells over a folder, open it after a short delay so the
/// drag can descend a tree without dropping first (Finder's behavior). A view arms this from its
/// drop-validation with the folder under the pointer; re-arming the same folder keeps the running
/// timer, a different folder restarts it, and nil cancels. Shared by every pane view.
@MainActor
final class SpringLoader {
    /// Dwell before a folder springs open.
    var delay: TimeInterval = 0.6

    private var currentKey: String?
    private var pendingAction: (() -> Void)?
    private var timer: Timer?

    /// Arm (or re-arm) for the folder identified by `key`, running `action` once the dwell elapses.
    /// Same key → keep counting; new key → restart; nil → cancel.
    func arm(key: String?, action: @escaping () -> Void) {
        if key == currentKey { return }
        cancel()
        guard let key else { return }
        currentKey = key
        pendingAction = action
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fire = self.pendingAction
                self.reset()
                fire?()
            }
        }
    }

    /// Stop any pending spring (call on drop, on leaving every folder, or when the drag ends).
    func cancel() { reset() }

    private func reset() {
        timer?.invalidate()
        timer = nil
        currentKey = nil
        pendingAction = nil
    }
}
