import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileViewMetadataTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) -> String {
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
            return "Fixture Editor"
        }
        var recorded: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    @Test func ordinaryListingDoesNotRequestOrResolveMetadata() {
        let calls = Calls()
        let entry = FileEntry(
            name: "not-present.txt", isDirectory: false, size: 0, modificationDate: nil,
            location: "/unavailable/fixture")
        let input = [entry]
        let result = FileViewMetadata.enrich(
            input, directory: URL(fileURLWithPath: "/unavailable/fixture"),
            requirements: ViewFormat.default.metadataRequirements,
            applicationName: { calls.record($0) })
        #expect(result == input)
        #expect(result.first?.viewMetadata == nil)
        #expect(calls.recorded.isEmpty)
    }

    @Test func remoteProviderMetadataSurvivesEnrichmentWithoutLocalReads() {
        let metadata = FileViewMetadata(
            kind: "Provider Document", dateAdded: Date(timeIntervalSince1970: 100),
            lastOpenedDate: Date(timeIntervalSince1970: 200), tagNames: ["Client Alpha"],
            applicationName: "Provider Editor")
        let entry = FileEntry(
            name: "remote.txt", isDirectory: false, size: 0, modificationDate: nil,
            location: "/unavailable/provider", viewMetadata: metadata)
        let calls = Calls()
        let result = FileViewMetadata.enrich(
            [entry], directory: nil,
            requirements: [.kind, .dateAdded, .lastOpened, .tags, .application],
            allowEntryLocations: false, applicationName: { calls.record($0) })
        #expect(result[0].viewMetadata == metadata)
        #expect(calls.recorded.isEmpty)
    }

    @Test func remoteEntriesCannotReadEntryLocationsOrResolveLocalApplications() {
        let calls = Calls()
        let remote = FileEntry(
            name: "fixture.txt", isDirectory: false, size: 0, modificationDate: nil,
            accessDate: Date(), location: FileManager.default.temporaryDirectory.path)
        let folder = FileEntry(name: "Folder", isDirectory: true, size: 0, modificationDate: nil)
        let result = FileViewMetadata.enrich(
            [remote, folder], directory: nil,
            requirements: [.kind, .tags, .dateAdded, .lastOpened, .application],
            allowEntryLocations: false,
            applicationName: { calls.record($0) })
        #expect(result[0].viewMetadata?.kind?.isEmpty == false)
        #expect(result[0].viewMetadata?.tagNames == [])
        #expect(result[0].viewMetadata?.dateAdded == nil)
        #expect(result[0].viewMetadata?.lastOpenedDate == nil)
        #expect(result[0].viewMetadata?.applicationName == nil)
        #expect(result[1].viewMetadata?.kind == "Folder")
        #expect(calls.recorded.isEmpty)
    }

    @Test func gathersOnlyRequestedFixtureMetadataWithoutUsingModificationAsDateAdded() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(
            "pathem-view-metadata-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        let oldModification = Date(timeIntervalSince1970: 100)
        try fm.setAttributes([.modificationDate: oldModification], ofItemAtPath: file.path)
        try FileMetadata.setTags(["Client Alpha", "Work"], on: file)
        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let entries = [FileEntry(contentsOf: file), FileEntry(contentsOf: folder)]
        let calls = Calls()
        let result = FileViewMetadata.enrich(
            entries, directory: directory, requirements: [.kind, .dateAdded, .tags, .application],
            applicationName: { calls.record($0) })
        let actual = try file.resourceValues(forKeys: [
            .addedToDirectoryDateKey, .localizedTypeDescriptionKey, .tagNamesKey,
        ])
        #expect(result[0].viewMetadata?.dateAdded == actual.addedToDirectoryDate)
        if let added = result[0].viewMetadata?.dateAdded { #expect(added != oldModification) }
        #expect(result[0].viewMetadata?.kind == actual.localizedTypeDescription)
        #expect(result[0].viewMetadata?.tagNames == ["Client Alpha", "Work"])
        #expect(result[0].viewMetadata?.applicationName == "Fixture Editor")
        #expect(result[1].viewMetadata?.applicationName == nil)
        #expect(calls.recorded == [file])
        // The resolver is not called merely because there is a local file.
        let otherCalls = Calls()
        let kindOnly = FileViewMetadata.enrich(
            entries, directory: directory, requirements: .kind,
            applicationName: { otherCalls.record($0) })
        #expect(kindOnly[0].viewMetadata?.dateAdded == nil)
        #expect(kindOnly[0].viewMetadata?.tagNames == [])
        #expect(otherCalls.recorded.isEmpty)
        // A smart result's explicit local parent is honored only when allowed.
        let smart = FileViewMetadata.enrich(entries, directory: nil, requirements: [.tags])
        #expect(smart[0].viewMetadata?.tagNames == ["Client Alpha", "Work"])
        // This negative control has the same basename and different metadata.
        // An entry's actual location must win over an unrelated pane parent.
        let wrongFile = folder.appendingPathComponent("fixture.txt")
        try Data("other".utf8).write(to: wrongFile)
        try FileMetadata.setTags(["Wrong Parent"], on: wrongFile)
        let crossFolder = FileViewMetadata.enrich(
            [entries[0]], directory: folder, requirements: .tags)
        #expect(crossFolder[0].viewMetadata?.tagNames == ["Client Alpha", "Work"])
        let explicitParent = FileEntry(
            name: "fixture.txt", isDirectory: false, size: 0, modificationDate: nil)
        let parentOnly = FileViewMetadata.enrich(
            [explicitParent], directory: folder, requirements: .tags)
        #expect(parentOnly[0].viewMetadata?.tagNames == ["Wrong Parent"])
    }

    @Test func missingSpotlightLastOpenedRemainsUnknownEvenWithAccessDate() {
        let entry = FileEntry(
            name: "absent-\(UUID().uuidString)", isDirectory: false, size: 0, modificationDate: nil,
            accessDate: Date())
        let enriched = FileViewMetadata.enrich(
            [entry], directory: FileManager.default.temporaryDirectory, requirements: .lastOpened)
        #expect(enriched[0].viewMetadata != nil)
        #expect(enriched[0].viewMetadata?.lastOpenedDate == nil)
        #expect(enriched[0].accessDate == entry.accessDate)
    }
}
