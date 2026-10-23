import Foundation
import Testing

@testable import PathemEngine

struct SessionScratchTests {
    @Test func preparationNeverSweepsAnotherSessionOrAnExistingWorkingCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scratch-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let first = SessionScratch(base: root)
        let second = SessionScratch(base: root)
        #expect(first.root != second.root)
        try first.prepare()
        let remote = first.remote.appendingPathComponent("editing.txt")
        let archive = first.archives.appendingPathComponent("working.txt")
        try Data("unsaved remote edits".utf8).write(to: remote)
        try Data("unsaved archive edits".utf8).write(to: archive)
        try second.prepare()
        try first.prepare()
        #expect(try Data(contentsOf: remote) == Data("unsaved remote edits".utf8))
        #expect(try Data(contentsOf: archive) == Data("unsaved archive edits".utf8))
        #expect(fm.fileExists(atPath: second.remote.path))
    }
}
