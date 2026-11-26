import Foundation
import PathemEngine

extension Notification.Name {
    /// Posted on the main thread after a record has been written to (or cleared from) the log.
    static let pathemActivityLogChanged = Notification.Name("pathem.activityLogChanged")
}

/// The app's single writer for the local activity log. Writes happen on a utility queue so a
/// file operation never waits on log I/O; the "Keep an activity log" setting gates every record.
final class OperationLogger: @unchecked Sendable {
    @MainActor static let shared = OperationLogger()

    let log: OperationLog?
    private let queue = DispatchQueue(label: "pathem.activity-log", qos: .utility)
    private let lock = NSLock()
    private var isEnabled = true

    @MainActor private init() {
        // Other debug launch modes may use automatic fixtures without a config override.
        // They must never record paths into the interactive history.
        let environment = ProcessInfo.processInfo.environment
        if PathemApp.isAutomationLaunch(environment: environment),
            environment["PATHEM_CONFIG_DIR"] == nil
        {
            log = nil
        } else {
            log = ConfigStore.directory().map { OperationLog(directory: $0) }
        }
    }

    var enabled: Bool {
        get { lock.withLock { isEnabled } }
        set { lock.withLock { isEnabled = newValue } }
    }

    func record(_ record: OperationRecord) {
        guard record.admin || enabled, let log else { return }
        queue.async {
            guard record.admin || self.enabled, log.append(record) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pathemActivityLogChanged, object: nil)
            }
        }
    }

    /// Newest first, read off the caller's thread.
    func entries(limit: Int = 2000) async -> [OperationRecord] {
        guard let log else { return [] }
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: log.entries(limit: limit)) }
        }
    }

    func clear() {
        guard let log else { return }
        queue.async {
            log.clear()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pathemActivityLogChanged, object: nil)
            }
        }
    }
}
