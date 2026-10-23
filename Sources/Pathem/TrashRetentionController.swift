import Foundation
import PathemEngine

extension Notification.Name {
    static let pathemTrashRetentionChanged = Notification.Name("pathemTrashRetentionChanged")
}

@MainActor
final class TrashRetentionController {
    static let shared = TrashRetentionController()
    private var timer: Timer?
    private var running = false
    private var worker: Task<TrashRetention.Outcome, Never>?
    private var preference: Bool?
    var enabled: Bool { preference ?? false }
    #if DEBUG
    var debugHasScheduledWork: Bool { timer != nil || worker != nil || running }
    #endif

    /// Only the first persisted load seeds this process. Other windows adopt its current value.
    func initialize(enabled: Bool) {
        guard preference == nil else { return }
        setPreference(enabled)
    }

    /// Called only by an explicit retention control, never by a full stale Preferences snapshot.
    func setPreference(_ enabled: Bool) {
        preference = enabled
        NotificationCenter.default.post(name: .pathemTrashRetentionChanged, object: self)
        schedule(enabled)
    }

    private func schedule(_ enabled: Bool) {
        guard enabled, !PathemApp.isAutomationLaunch else {
            timer?.invalidate()
            timer = nil
            worker?.cancel()
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        timer?.tolerance = 60
        run()
    }

    private func run() {
        guard !running else { return }
        running = true
        let work = Task.detached(priority: .utility) { TrashRetention.cleanHomeTrash() }
        worker = work
        Task { @MainActor in
            let result = await work.value
            running = false
            worker = nil
            if result.failed > 0 {
                NSLog(
                    "Pathem Trash retention: %d removed, %d retained; %d could not be removed. Only items with a known Trash date older than 30 days were eligible.",
                    result.removed, result.retained, result.failed)
            }
        }
    }
}
