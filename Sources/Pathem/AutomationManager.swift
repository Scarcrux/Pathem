import AppKit
import PathemEngine

/// Owns the saved automation rules, persists them, and keeps a folder watcher on each
/// watched folder so a matching new arrival triggers the rule automatically. Also supports
/// a manual "Run Now" over each folder's current contents.
@MainActor
final class AutomationManager {
    private(set) var rules: [AutomationRule] = []
    private var watchers: [String: DirectoryWatcher] = [:]
    private var known: [String: Set<String>] = [:]
    private let storeURL: URL?
    /// Called (on the main actor) after rules act, so the browser can reload the panes.
    var onApplied: (([AutomationEngine.Outcome]) -> Void)?

    private static let partialExtensions: Set<String> = ["crdownload", "part", "download", "partial"]

    init(storeURL: URL?) {
        self.storeURL = storeURL
        load()
    }

    func setRules(_ rules: [AutomationRule]) {
        self.rules = rules
        persist()
        restartWatchers()
    }

    private func load() {
        if let url = storeURL, let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([AutomationRule].self, from: data)
        {
            rules = decoded
        }
        restartWatchers()
    }

    private func persist() {
        guard let url = storeURL, let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: url)
    }

    /// Apply every enabled rule to its folder's current contents.
    @discardableResult
    func runNow() -> [AutomationEngine.Outcome] {
        let folders = Set(rules.filter(\.enabled).map(\.folderPath))
        var outcomes: [AutomationEngine.Outcome] = []
        for folder in folders {
            outcomes += AutomationEngine.run(rules, in: URL(fileURLWithPath: folder))
            known[folder] = names(URL(fileURLWithPath: folder))  // reseed so the watcher doesn't re-fire
        }
        if !outcomes.isEmpty { onApplied?(outcomes) }
        return outcomes
    }

    /// Stop and drop every folder watcher (called on window teardown so a self-retained FSEvents
    /// stream doesn't outlive the window). Idempotent.
    func stopWatching() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        known.removeAll()
    }

    /// True while at least one folder is being watched (teardown-leak smoke guard).
    var debugIsWatching: Bool { !watchers.isEmpty }

    private func restartWatchers() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        known.removeAll()
        for folder in Set(rules.filter(\.enabled).map(\.folderPath)) where !folder.isEmpty {
            let url = URL(fileURLWithPath: folder)
            known[folder] = names(url)
            watchers[folder] = DirectoryWatcher(path: folder) { [weak self] in
                Task { @MainActor in self?.folderChanged(folder) }
            }
        }
    }

    private func folderChanged(_ folder: String) {
        let url = URL(fileURLWithPath: folder)
        let current = names(url)
        let arrived = current.subtracting(known[folder] ?? [])
        known[folder] = current
        guard !arrived.isEmpty else { return }
        let folderRules = rules.filter { $0.enabled && $0.folderPath == folder }
        var outcomes: [AutomationEngine.Outcome] = []
        for name in arrived.sorted() {
            // Skip in-progress downloads; act on the finished file.
            if Self.partialExtensions.contains((name as NSString).pathExtension.lowercased()) { continue }
            let file = url.appendingPathComponent(name)
            if let rule = folderRules.first(where: { AutomationEngine.matches($0, file: file) }) {
                outcomes.append(AutomationEngine.apply(rule, to: file))
            }
        }
        known[folder] = names(url)  // moved/trashed files have left
        if !outcomes.isEmpty { onApplied?(outcomes) }
    }

    private func names(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}
