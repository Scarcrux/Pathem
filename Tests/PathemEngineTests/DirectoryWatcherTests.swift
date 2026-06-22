import Foundation
import Testing

@testable import PathemEngine

@Suite struct DirectoryWatcherTests {
    /// Creates a file in a watched directory and confirms the watcher fires.
    /// FSEvents is asynchronous, so this waits a couple of seconds.
    @Test func firesWhenAFileIsCreated() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-watch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try await confirmation(expectedCount: 1...) { changed in
            guard let watcher = DirectoryWatcher(path: dir.path, latency: 0.1, onChange: { changed() })
            else {
                Issue.record("watcher failed to start")
                return
            }
            // Let the stream arm, create a file, then wait for the event.
            try await Task.sleep(for: .milliseconds(300))
            try Data("hi".utf8).write(to: dir.appendingPathComponent("new.txt"))
            try await Task.sleep(for: .seconds(2))
            watcher.stop()  // tear down (no deinit auto-stop), so it can't fire after the test
        }
    }

    /// Hammers the teardown path: create a watcher, cause an event, stop it, in a
    /// tight loop. Exercises the create/fire/stop race the lifetime + queue-synced
    /// teardown fix is meant to make safe. A regression (use-after-free or a
    /// deadlock in stop()) would crash or hang here.
    @Test func rapidStartStopIsSafe() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-watch-stress-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        for i in 0..<50 {
            let watcher = DirectoryWatcher(path: dir.path, latency: 0) {}
            try Data("\(i)".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
            watcher?.stop()
        }
        #expect(Bool(true))  // reached here without crashing or hanging
    }
}

