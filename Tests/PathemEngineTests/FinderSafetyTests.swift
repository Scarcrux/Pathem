import Foundation
import Testing

@testable import PathemEngine

struct FinderSafetyTests {
    @Test func retentionIsOptInAndWarningDefaultsOn() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(
            !prefs.trashAfter30Days && prefs.warnBeforeChangingExtension && prefs.suggestFilenames)
        var enabled = prefs
        enabled.trashAfter30Days = true
        enabled.warnBeforeChangingExtension = false
        enabled.suggestFilenames = false
        #expect(
            try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(enabled))
                == enabled)
    }

    @Test func extensionChangesHaveContrastingControls() {
        #expect(
            !RenamePolicy.changesExtension(
                from: "untitled file", to: "notes.txt", isDirectory: false))
        #expect(RenamePolicy.changesExtension(from: "a.txt", to: "a.pdf", isDirectory: false))
        #expect(RenamePolicy.changesExtension(from: "a.txt", to: "a", isDirectory: false))
        #expect(!RenamePolicy.changesExtension(from: "a.txt", to: "b.TXT", isDirectory: false))
        #expect(!RenamePolicy.changesExtension(from: ".env", to: ".config", isDirectory: false))
        #expect(!RenamePolicy.changesExtension(from: "a.txt", to: "a.pdf", isDirectory: true))
    }

    @Test func retentionRemovesOnlyKnownOldEntriesAndNeverFollowsLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)")
        let trash = root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["old", "young", "unknown", "boundary"] {
            try Data("bytes".utf8).write(to: trash.appendingPathComponent(name))
        }
        let outside = root.appendingPathComponent("outside")
        try Data("protected".utf8).write(to: outside)
        try fm.createSymbolicLink(
            at: trash.appendingPathComponent("link"), withDestinationURL: outside)
        let oldDirectory = trash.appendingPathComponent("old-directory")
        try fm.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: oldDirectory.appendingPathComponent("nested-link"), withDestinationURL: outside)
        let now = Date()
        let outcome = TrashRetention.clean(directory: trash, now: now) { url in
            switch url.lastPathComponent {
            case "old", "link", "old-directory": return now.addingTimeInterval(-31 * 86400)
            case "young": return now.addingTimeInterval(-86400)
            case "boundary": return now.addingTimeInterval(-30 * 86400)
            default: return nil
            }
        }
        #expect(outcome.removed == 2 && outcome.retained == 4 && outcome.failed == 0)
        #expect(!fm.fileExists(atPath: trash.appendingPathComponent("old").path))
        #expect(try Data(contentsOf: outside) == Data("protected".utf8))
        #expect(!fm.fileExists(atPath: oldDirectory.path))
        #expect(fm.fileExists(atPath: trash.appendingPathComponent("unknown").path))
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: trash)
        let blocked = TrashRetention.clean(directory: alias, now: now) { _ in .distantPast }
        #expect(blocked.removed == 0)
        #expect(fm.fileExists(atPath: trash.appendingPathComponent("young").path))
        let replaced = trash.appendingPathComponent("replaced")
        let original = root.appendingPathComponent("original-backup")
        try Data("original".utf8).write(to: replaced)
        var delivered = false
        let replacement = TrashRetention.clean(directory: trash, now: now) { url in
            guard url.lastPathComponent == "replaced" else { return nil }
            if !delivered {
                do {
                    try fm.moveItem(at: replaced, to: original)
                    try Data("new occupant".utf8).write(to: replaced)
                    delivered = true
                } catch { Issue.record("Could not deliver the replacement fixture") }
            }
            return .distantPast
        }
        #expect(delivered && replacement.removed == 0)
        #expect(try Data(contentsOf: replaced) == Data("new occupant".utf8))
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func filesystemDateAddedMeasuresEntryNotContentAge() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("entry-age-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("trash-fixture")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("old-content.txt")
        try Data("old content".utf8).write(to: source)
        try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: source.path)
        let before = Date().addingTimeInterval(-2)
        let moved = destination.appendingPathComponent(source.lastPathComponent)
        try fm.moveItem(at: source, to: moved)
        let values = try moved.resourceValues(forKeys: [
            .addedToDirectoryDateKey, .contentModificationDateKey,
        ])
        let entered = try #require(values.addedToDirectoryDate)
        #expect(entered >= before)
        #expect((values.contentModificationDate ?? .distantFuture) < before)
    }
}
