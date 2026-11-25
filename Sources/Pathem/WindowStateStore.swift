import Foundation
import PathemEngine

/// Persists window state across launches: the restore session (each side's tab folders),
/// saved workspaces, and named view Styles. Owns the models, their files, and the session's
/// debounce + no-op-write dedup -- state that used to live loose on BrowserViewController.
/// The browser captures state from its panes and applies it back; this only stores it.
@MainActor
final class WindowStateStore {
    /// The last window session: each side's tab folders, active tab, and which side is active.
    struct Session: Codable, Equatable {
        var left: [String]
        var leftActive: Int
        var right: [String]
        var rightActive: Int
        var leftIsActive: Bool
        /// Which tabs are locked, parallel to `left` / `right`. Absent in older sessions (none locked).
        var leftLocked: [Bool]
        var rightLocked: [Bool]

        init(
            left: [String], leftActive: Int, right: [String], rightActive: Int, leftIsActive: Bool,
            leftLocked: [Bool] = [], rightLocked: [Bool] = []
        ) {
            self.leftLocked = leftLocked
            self.rightLocked = rightLocked
            self.left = left
            self.leftActive = leftActive
            self.right = right
            self.rightActive = rightActive
            self.leftIsActive = leftIsActive
        }

        // Tolerant: a partial/older session.json restores what it can instead of failing the
        // whole decode (which would discard the session entirely).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            left = try c.decodeIfPresent([String].self, forKey: .left) ?? []
            leftActive = try c.decodeIfPresent(Int.self, forKey: .leftActive) ?? 0
            right = try c.decodeIfPresent([String].self, forKey: .right) ?? []
            rightActive = try c.decodeIfPresent(Int.self, forKey: .rightActive) ?? 0
            leftIsActive = try c.decodeIfPresent(Bool.self, forKey: .leftIsActive) ?? true
            leftLocked = try c.decodeIfPresent([Bool].self, forKey: .leftLocked) ?? []
            rightLocked = try c.decodeIfPresent([Bool].self, forKey: .rightLocked) ?? []
        }
    }

    struct Workspace: Codable, Equatable {
        var name: String
        var left: [String]
        var leftActive: Int
        var right: [String]
        var rightActive: Int
    }

    struct Style: Codable, Equatable {
        var name: String
        var format: ViewFormat
    }

    private var lastSavedSession: Session?
    private var pendingSave: DispatchWorkItem?

    // MARK: - Session

    func loadSession() -> Session? { ConfigStore.load(Session.self, from: Self.sessionURL) }

    /// Write immediately, skipping a no-op write (e.g. a watcher tick that didn't change tabs).
    func saveSession(_ state: Session) {
        guard state != lastSavedSession else { return }
        lastSavedSession = state
        ConfigStore.save(state, to: Self.sessionURL)
    }

    /// Persist a moment after a change (coalesces navigation bursts). `capture` runs when the
    /// timer fires, so it grabs the latest state; returning nil (e.g. demo mode) skips the save.
    func scheduleSessionSave(capturing capture: @escaping @MainActor () -> Session?) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if let state = capture() { self?.saveSession(state) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Workspaces

    func workspaces() -> [Workspace] {
        ConfigStore.load([Workspace].self, from: Self.workspacesURL) ?? []
    }

    /// Add or replace a workspace by name.
    func saveWorkspace(_ workspace: Workspace) {
        var all = workspaces()
        all.removeAll { $0.name == workspace.name }
        all.append(workspace)
        ConfigStore.save(all, to: Self.workspacesURL)
    }

    // MARK: - Tab groups

    func tabGroups() -> TabGroupStore {
        ConfigStore.load(TabGroupStore.self, from: Self.tabGroupsURL) ?? TabGroupStore()
    }

    func saveTabGroups(_ store: TabGroupStore) { ConfigStore.save(store, to: Self.tabGroupsURL) }

    // MARK: - Styles

    func styles() -> [Style] { ConfigStore.load([Style].self, from: Self.stylesURL) ?? [] }

    /// Add or replace a Style by name.
    func saveStyle(_ style: Style) {
        var all = styles()
        all.removeAll { $0.name == style.name }
        all.append(style)
        ConfigStore.save(all, to: Self.stylesURL)
    }

    // MARK: - Files

    private static var sessionURL: URL? { ConfigStore.url("session.json") }
    private static var workspacesURL: URL? { ConfigStore.url("workspaces.json") }
    private static var tabGroupsURL: URL? { ConfigStore.url("tab-groups.json") }
    private static var stylesURL: URL? { ConfigStore.url("styles.json") }
}
