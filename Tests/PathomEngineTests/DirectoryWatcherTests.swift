import Foundation
import Testing

@testable import PathomEngine

@Suite struct DirectoryWatcherTests {
    /// Creates a file in a watched directory and confirms the watcher fires.
    /// FSEvents is asynchronous, so this waits a couple of seconds.
    @Test func firesWhenAFileIsCreated() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathom-watch-\(UUID().uuidString)")
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
            withExtendedLifetime(watcher) {}
        }
    }
}
