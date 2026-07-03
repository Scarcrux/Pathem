import Foundation
import Testing

@testable import PathemEngine

@Suite struct OrganizePlannerTests {
    // MARK: Helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-organize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file old enough to clear the freshness guard. Content defaults to the file name
    /// so distinct files aren't accidental content-duplicates; pass equal content to make
    /// a deliberate duplicate.
    @discardableResult
    private func makeFile(
        _ name: String, in dir: URL, content: String? = nil, daysOld: Double = 10
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((content ?? name).utf8).write(to: url)
        let date = Date(timeIntervalSinceNow: -daysOld * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    private func setWhereFrom(_ urls: [String], on file: URL) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: urls, format: .binary, options: 0)
        else { return }
        _ = data.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0)
        }
    }

    private func suggestion(for name: String, in list: [OrganizePlanner.Suggestion])
        -> OrganizePlanner.Suggestion?
    {
        list.first { $0.file.lastPathComponent == name }
    }

    // MARK: Rules

    @Test func tidiesLooseFilesByKind() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile("photo.png", in: dir)
        try makeFile("report.pdf", in: dir)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        let image = try #require(suggestion(for: "photo.png", in: plan))
        #expect(image.destination?.lastPathComponent == "Images")
        #expect(image.ruleID == "by-kind")
        #expect(image.accepted)  // in-folder tidy is auto-accepted
        let pdf = try #require(suggestion(for: "report.pdf", in: plan))
        #expect(pdf.destination?.lastPathComponent == "PDFs")
        #expect(pdf.accepted)
    }

    @Test func trashesJunkAndIncompleteDownloads() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(".DS_Store", in: dir)
        try makeFile("movie.mp4.crdownload", in: dir)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        let junk = try #require(suggestion(for: ".DS_Store", in: plan))
        #expect(junk.kind == .trash)
        #expect(junk.ruleID == "junk")
        #expect(junk.accepted)
        let partial = try #require(suggestion(for: "movie.mp4.crdownload", in: plan))
        #expect(partial.kind == .trash)
        #expect(partial.ruleID == "incomplete")
    }

    @Test func trashesDuplicateExtrasKeepingNewest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Identical content, extension in no kind map, so the only suggestion is the dedupe.
        try makeFile("older.bin", in: dir, content: "same", daysOld: 10)
        try makeFile("newer.bin", in: dir, content: "same", daysOld: 3)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        #expect(plan.count == 1)
        let dup = try #require(plan.first)
        #expect(dup.file.lastPathComponent == "older.bin")  // the newer copy is kept
        #expect(dup.kind == .trash)
        #expect(dup.ruleID == "duplicate")
        #expect(dup.rationale.contains("newer.bin"))
    }

    @Test func skipsFreshFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile("just-saved.png", in: dir, daysOld: 0)  // within the 24h grace window

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        #expect(plan.isEmpty)
    }

    @Test func skipsFilesInsideGitRepos() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try makeFile("photo.png", in: dir)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        #expect(plan.isEmpty)  // git is the backup; never reorganize a working tree
    }

    @Test func installerSurfacedButUncheckedByDefault() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile("Some App.dmg", in: dir)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        let installer = try #require(suggestion(for: "Some App.dmg", in: plan))
        #expect(installer.kind == .trash)
        #expect(installer.ruleID == "installer")
        #expect(!installer.accepted)  // low confidence: shown for review, not pre-checked
    }

    @Test func routesScreenshotsToTheScreenshotsDestination() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("Shots")
        let destinations = FilingDestinations(destinations: [.init(name: "Screenshots", url: shots)])
        try makeFile("Screenshot 2024-01-01 at 10.00.00.png", in: dir)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: destinations)
        let shot = try #require(plan.first)
        #expect(shot.ruleID == "screenshots")  // beats the generic by-kind image rule
        #expect(shot.destination == shots)
        #expect(shot.accepted)
    }

    @Test func includesDownloadHostInRationale() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try makeFile("invoice.pdf", in: dir)
        setWhereFrom(["https://billing.stripe.com/invoice.pdf"], on: pdf)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        let s = try #require(suggestion(for: "invoice.pdf", in: plan))
        #expect(s.rationale.contains("billing.stripe.com"))
    }

    @Test func everySuggestionHasARationale() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile("a.png", in: dir)
        try makeFile("b.pdf", in: dir)
        try makeFile(".DS_Store", in: dir)

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        #expect(!plan.isEmpty)
        #expect(plan.allSatisfy { !$0.rationale.isEmpty })
    }

    // MARK: Apply

    @Test func applyMovesTrashesAndIsUndoable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try makeFile("photo.png", in: dir)
        let partial = try makeFile("leftover.crdownload", in: dir)  // a reliably-trashable junk file

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        let outcome = OrganizePlanner.apply(plan)

        #expect(outcome.moved == 1)
        #expect(outcome.trashed == 1)
        #expect(outcome.failures.isEmpty)
        let moved = dir.appendingPathComponent("Images/photo.png")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: photo.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        // The undo records reverse the moves exactly like any other local file op.
        _ = FileOperations.undo(outcome.performed)
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func applyIgnoresUnacceptedSuggestions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installer = try makeFile("Some App.dmg", in: dir)  // suggested but unchecked
        try makeFile("photo.png", in: dir)  // accepted

        let plan = OrganizePlanner.suggestions(for: dir, destinations: FilingDestinations())
        _ = OrganizePlanner.apply(plan)

        #expect(FileManager.default.fileExists(atPath: installer.path))  // untouched
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Images/photo.png").path))
    }
}
