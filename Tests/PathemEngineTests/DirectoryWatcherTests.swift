import Foundation
import Testing

@testable import PathemEngine

@Suite struct DirectoryWatcherTests {
    /// Creates files in a watched directory and confirms the watcher fires. FSEvents is
    /// asynchronous and the stream arms after `FSEventStreamStart` returns, so a single write
    /// after a fixed sleep can race the arm and be lost forever (the stream is SinceNow). Instead
    /// poll up to a generous budget, re-touching the folder each pass: a write inside the armed
    /// window still fires, we succeed the instant it does, and we only fail if nothing lands across
    /// ~100 writes in 10s (a true regression). No fixed-sleep timing assumptions.
    @Test func firesWhenAFileIsCreated() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-watch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Thread-safe: the FSEvents callback queue sets it, the test polls it.
        final class Fired: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() {
                lock.lock()
                value = true
                lock.unlock()
            }
            var isSet: Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let fired = Fired()
        guard
            let watcher = DirectoryWatcher(path: dir.path, latency: 0.05, onChange: { fired.set() })
        else {
            Issue.record("watcher failed to start")
            return
        }
        defer { watcher.stop() }  // no deinit auto-stop; must stop explicitly

        let deadline = Date().addingTimeInterval(10)
        var n = 0
        while !fired.isSet, Date() < deadline {
            n += 1
            try Data("hi".utf8).write(to: dir.appendingPathComponent("new-\(n).txt"))
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(fired.isSet)
    }

    /// Hammers the teardown path: create a watcher, cause an event, stop it, in a
    /// tight loop. Exercises the create/fire/stop race the lifetime + queue-synced
    /// teardown fix is meant to make safe. A regression (use-after-free or a
    /// deadlock in stop()) would crash or hang here.
    @Test func rapidStartStopIsSafe() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "pathem-watch-stress-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        for i in 0..<50 {
            let watcher = DirectoryWatcher(path: dir.path, latency: 0) {}
            try Data("\(i)".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
            watcher?.stop()
        }
        #expect(Bool(true))  // reached here without crashing or hanging
    }

    /// Only the watched folder itself or a direct entry changes its listing; a deep-subtree change
    /// does not. This filter is what stops watching a busy tree (worst case "/") from reloading the
    /// pane several times a second on unrelated system activity.
    @Test func onlyDirectEntriesAndTheFolderItselfAffectTheListing() {
        #expect(
            DirectoryWatcher.pathAffectsListing(
                event: "/fixture/home/a.txt", watched: "/fixture/home"))
        #expect(
            DirectoryWatcher.pathAffectsListing(
                event: "/fixture/home/sub", watched: "/fixture/home"))
        #expect(
            DirectoryWatcher.pathAffectsListing(event: "/fixture/home", watched: "/fixture/home"))  // WatchRoot
        #expect(DirectoryWatcher.pathAffectsListing(event: "/Applications", watched: "/"))
        // Deep changes are ignored -- the flood the trace caught.
        #expect(
            !DirectoryWatcher.pathAffectsListing(
                event: "/fixture/home/sub/deep.txt", watched: "/fixture/home"))
        #expect(!DirectoryWatcher.pathAffectsListing(event: "/private/var/log/x", watched: "/"))
        #expect(
            !DirectoryWatcher.pathAffectsListing(
                event: "/Applications/A.app/Contents/x", watched: "/"))
    }
}
