import Foundation
import Testing

@testable import PathemEngine

struct RemoteDownloadDestinationTests {
    @Test func collidingNamesPreserveEveryPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-download-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("report.txt")
        try Data("existing".utf8).write(to: existing)

        let fixtures = [
            ("a/report.txt", "first"),
            ("b\\report.txt", "second"),
            ("report 2.txt", "explicit suffix"),
            ("unrelated.txt", "control"),
        ]
        var destinations = RemoteDownloadDestination(in: directory)
        let jobs = try fixtures.map { name, contents in
            let reserved = destinations.reserve(for: name)
            let target = try #require(reserved)
            return (target, Data(contents.utf8))
        }
        let unsafe = destinations.reserve(for: "..")
        #expect(unsafe == nil)
        #expect(
            jobs.map { $0.0.lastPathComponent } == [
                "report 2.txt", "report 3.txt", "report 2 2.txt", "unrelated.txt",
            ])

        // Record every planned provider target before any provider writes its bytes.
        for (target, bytes) in jobs { try bytes.write(to: target) }
        for (target, bytes) in jobs { #expect(try Data(contentsOf: target) == bytes) }
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    }
}
