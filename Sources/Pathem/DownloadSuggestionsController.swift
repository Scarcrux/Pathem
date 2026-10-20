import AppKit
import PathemEngine

/// Watches the Downloads folder and, when a new file arrives that has a confident filing
/// destination, floats a one-click "Move X to Y?" chip. Owns the FSEvents watcher, the
/// pending-suggestion queue, and the chip view -- state that used to live loose on
/// BrowserViewController. The browser positions the chip and, via `onApplied`, registers the
/// undo and refreshes its panes; everything else lives here.
@MainActor
final class DownloadSuggestionsController {
    private let bar = DownloadSuggestionBar()
    private var watcher: DirectoryWatcher?
    private var known: Set<String> = []
    private var pending: [OrganizePlanner.Suggestion] = []
    private var current: OrganizePlanner.Suggestion?
    private var folderOverride: URL?
    private var feedbackURL: URL?
    /// One window owns a path while it is queued/shown/applied. Values are
    /// session tokens, so a late completion cannot release a newer session's claim.
    private static var claims: [String: UUID] = [:]
    private var session = UUID()
    private var enabled = false

    /// The chip view; the browser adds and positions it in the window.
    var view: NSView { bar }

    /// Called after a move is applied, so the browser can register undo and reload its panes.
    var onApplied: (([FileOperations.Performed]) -> Void)?

    init() {
        bar.onMove = { [weak self] in self?.apply() }
        bar.onDismiss = { [weak self] in self?.dismiss() }
        bar.onDismissAll = { [weak self] in self?.dismissAll() }
    }

    /// Begin watching Downloads. The caller skips this in demo mode and under the smoke
    /// harness (which must stay deterministic). `feedbackURL` is where accept/skip signal is
    /// recorded so suggestions learn from the user.
    func start(feedbackURL: URL?) {
        guard !enabled else { return }  // applying unrelated preferences must not reset history
        enabled = true
        self.feedbackURL = feedbackURL
        let folder = downloadsFolder
        known = Self.names(in: folder)  // seed: only later arrivals count as "new"
        watcher = DirectoryWatcher(path: folder.path) { [weak self] in
            Task { @MainActor in self?.didChange() }
        }
    }

    func stop() {
        enabled = false
        watcher?.stop()
        watcher = nil
        Self.claims = Self.claims.filter { $0.value != session }
        session = UUID()
        pending = []
        current = nil
        known = []
        bar.hide()
    }

    /// Whether the Downloads folder is being watched (teardown-leak smoke guard).
    var debugIsWatching: Bool { watcher != nil }

    private var downloadsFolder: URL {
        folderOverride
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private static func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    private func didChange() {
        guard enabled else { return }
        let folder = downloadsFolder
        let currentNames = Self.names(in: folder)
        let arrived = currentNames.subtracting(known)
        // A save can replace a file through an observed absent/present interval.
        // Optional ambient UI offers each path only once per enabled session.
        known.formUnion(currentNames)
        guard !arrived.isEmpty else { return }
        let destinations = FilingDestinations.defaults(
            home: FileManager.default.homeDirectoryForCurrentUser)
        let memory = feedbackURL.map { OrganizeFeedback.load(from: $0) } ?? OrganizeFeedback()
        for name in arrived.sorted() {
            let ext = (name as NSString).pathExtension.lowercased()
            // Ignore partial downloads and dotfiles; wait for the finished file.
            if name.hasPrefix(".") || ["crdownload", "part", "download", "partial"].contains(ext) {
                continue
            }
            let url = folder.appendingPathComponent(name)
            // Only offer to MOVE an arrival (never auto-prompt to trash a download).
            guard
                let suggestion = OrganizePlanner.suggestion(
                    for: url, destinations: destinations, memory: memory),
                case .move = suggestion.kind
            else { continue }
            let key = url.standardizedFileURL.path
            guard Self.claims[key] == nil else { continue }
            Self.claims[key] = session
            pending.append(suggestion)
        }
        showNext()
    }

    private func showNext() {
        guard enabled, bar.isHidden else { return }  // one chip at a time
        while !pending.isEmpty {
            let next = pending.removeFirst()
            // The file may already have been moved or deleted since it was queued.
            guard FileManager.default.fileExists(atPath: next.file.path),
                let dest = next.destination
            else {
                release(next.file, token: session)
                continue
            }
            current = next
            bar.show(fileURL: next.file, destinationName: dest.lastPathComponent)
            return
        }
    }

    private func apply() {
        guard let suggestion = current else { return }
        bar.hide()
        current = nil
        let token = session
        Task { @MainActor in
            var forced = suggestion  // the user clicked Move, so apply regardless of the default
            forced.accepted = true
            let outcome = await Task.detached { OrganizePlanner.apply([forced]) }.value
            if let url = self.feedbackURL {
                OrganizeFeedback.record(
                    .init(
                        ruleID: suggestion.ruleID,
                        destination: suggestion.destination?.lastPathComponent,
                        ext: suggestion.file.pathExtension.lowercased(), verdict: .applied), to: url
                )
            }
            self.onApplied?(outcome.performed)
            self.release(suggestion.file, token: token)
            if token == self.session { self.showNext() }
        }
    }

    private func dismiss() {
        guard let suggestion = current else { return }
        if let url = feedbackURL {
            OrganizeFeedback.record(
                .init(
                    ruleID: suggestion.ruleID,
                    destination: suggestion.destination?.lastPathComponent,
                    ext: suggestion.file.pathExtension.lowercased(), verdict: .skipped), to: url)
        }
        bar.hide()
        current = nil
        release(suggestion.file, token: session)
        showNext()
    }

    private func release(_ file: URL, token: UUID) {
        let key = file.standardizedFileURL.path
        if Self.claims[key] == token { Self.claims[key] = nil }
    }

    private func dismissAll() {
        let suggestions = current.map { [$0] } ?? []
        for suggestion in suggestions + pending {
            if let url = feedbackURL {
                OrganizeFeedback.record(
                    .init(
                        ruleID: suggestion.ruleID,
                        destination: suggestion.destination?.lastPathComponent,
                        ext: suggestion.file.pathExtension.lowercased(), verdict: .skipped), to: url
                )
            }
            release(suggestion.file, token: session)
        }
        current = nil
        pending = []
        bar.hide()
    }

    // MARK: - Debug hooks (the smoke integration check)

    var debugChipText: String? { bar.debugVisibleText }

    /// Point at a temp Downloads folder, seed the known set, and run one change pass.
    func debugRunCheck(folder: URL, seedKnown: Set<String>, feedbackURL: URL?) {
        enabled = true  // only this explicitly supplied disposable folder, never owner Downloads
        folderOverride = folder
        self.feedbackURL = feedbackURL
        known = seedKnown
        didChange()
    }

    func debugReset() {
        stop()
        folderOverride = nil
    }
    #if DEBUG
    var debugQueuedNames: [String] { pending.map { $0.file.lastPathComponent } }
    var debugCurrentName: String? { current?.file.lastPathComponent }
    var debugDismissAllButton: NSButton { bar.debugDismissAllButton }
    func debugRefresh() { didChange() }
    #endif
}
