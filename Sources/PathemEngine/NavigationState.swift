import Foundation

/// Per-pane navigation history: the current directory plus back/forward stacks.
///
/// Pure value logic (no AppKit), so the bug-prone part — history-stack
/// management — is unit-tested directly (CONVENTIONS: cover the load-bearing
/// logic). URLs are standardized so `/a/b` and `/a/b/` compare equal.
public struct NavigationState: Sendable, Equatable {
    public private(set) var current: URL
    public private(set) var backStack: [URL]
    public private(set) var forwardStack: [URL]

    public init(current: URL) {
        self.current = current.standardizedFileURL
        self.backStack = []
        self.forwardStack = []
    }

    /// Rebuild a state with known stacks (oldest first), e.g. for a reopened tab.
    public init(current: URL, back: [URL], forward: [URL]) {
        self.current = current.standardizedFileURL
        self.backStack = back.map(\.standardizedFileURL)
        self.forwardStack = forward.map(\.standardizedFileURL)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// The parent directory, or `nil` at the filesystem root.
    public var parent: URL? {
        let p = current.deletingLastPathComponent().standardizedFileURL
        return p.path != current.path ? p : nil
    }

    /// Jump to a directory without recording history: set it as current and clear
    /// both stacks. Used when swapping into or out of demo mode, so a throwaway temp
    /// path is never reachable via Back (and can't become a dead link once the temp
    /// directory is cleaned up).
    public mutating func reset(to url: URL) {
        current = url.standardizedFileURL
        backStack.removeAll()
        forwardStack.removeAll()
    }

    /// Navigate to a new directory: push the current one onto the back stack and
    /// clear the forward stack. No-op when it's the same directory.
    public mutating func go(to url: URL) {
        let target = url.standardizedFileURL
        guard target.path != current.path else { return }
        backStack.append(current)
        current = target
        forwardStack.removeAll()
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(current)
        current = previous
        return true
    }

    @discardableResult
    public mutating func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(current)
        current = next
        return true
    }

    @discardableResult
    public mutating func goUp() -> Bool {
        guard let p = parent else { return false }
        go(to: p)
        return true
    }
}
