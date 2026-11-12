import Foundation
import Testing

@testable import PathemEngine

@Suite struct ReclaimCatalogTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-reclaim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ bytes: Int, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    @Test func catalogIsWellFormed() {
        let places = ReclaimCatalog.places
        #expect(Set(places.map(\.id)).count == places.count)
        #expect(Set(places.map(\.relativePath)).count == places.count)
        #expect(
            places.allSatisfy { !$0.relativePath.hasPrefix("/") && !$0.relativePath.contains("..") }
        )
        // Things that may exist nowhere else are never in a tier that can skip the Trash.
        for id in [
            "xcode-archives", "simulator-devices", "docker-data", "ios-backups", "downloads",
        ] {
            #expect(places.first { $0.id == id }?.consequence == .review)
        }
    }

    @Test func listsOnlyPlacesThatExistPlusUncataloguedCaches() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(10, home.appendingPathComponent("Library/Caches/go-build/a"))
        try write(10, home.appendingPathComponent("Library/Caches/mystery-tool/a"))
        try write(10, home.appendingPathComponent(".cache/huggingface/m"))
        try write(10, home.appendingPathComponent("Library/Caches/loose-file"))
        let found = ReclaimCatalog.candidates(home: home)
        #expect(
            Set(found.map(\.place.id)) == [
                "go-build", "huggingface", "other:Library/Caches/mystery-tool",
            ])
        #expect(found.first { $0.place.id.hasPrefix("other:") }?.place.consequence == .review)
        #expect(found.first { $0.place.id == "huggingface" }?.place.consequence == .redownloads)
    }

    @Test func overlapCoversSameInsideAndContaining() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(10, home.appendingPathComponent("Library/Caches/go-build/a"))
        let found = ReclaimCatalog.candidates(home: home)
        let base = home.path
        #expect(ReclaimCatalog.overlaps(base + "/Library/Caches/go-build", with: found))
        #expect(ReclaimCatalog.overlaps(base + "/Library/Caches/go-build/x/y", with: found))
        #expect(ReclaimCatalog.overlaps(base + "/Library/Caches", with: found))
        #expect(!ReclaimCatalog.overlaps(base + "/Library/Caches/go-build2", with: found))
        #expect(!ReclaimCatalog.overlaps(base + "/Code/proj/.build", with: found))
    }

    @Test func deleteNowOnlyForTheRebuildsTierInsideHome() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try write(10, home.appendingPathComponent("Library/Caches/go-build/a/b"))
        try write(10, home.appendingPathComponent(".cache/huggingface/model"))
        try write(10, home.appendingPathComponent("Library/Caches/mystery-tool/a"))
        try write(10, home.appendingPathComponent("outside/keep"))
        let found = ReclaimCatalog.candidates(home: home)
        func candidate(_ id: String) -> ReclaimCatalog.Candidate {
            found.first { $0.place.id == id }!
        }

        try ReclaimCatalog.deleteNow(candidate("go-build"), home: home)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/go-build").path))
        #expect(
            try fm.contentsOfDirectory(
                atPath: home.appendingPathComponent("Library/Caches/go-build").path
            ).isEmpty)

        // Re-download and review tiers are refused and left untouched.
        #expect(throws: ReclaimCatalog.DeleteError.self) {
            try ReclaimCatalog.deleteNow(candidate("huggingface"), home: home)
        }
        #expect(throws: ReclaimCatalog.DeleteError.self) {
            try ReclaimCatalog.deleteNow(candidate("other:Library/Caches/mystery-tool"), home: home)
        }
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".cache/huggingface/model").path))

        // A forged candidate (rebuilds place, different folder) is refused.
        let goBuild = ReclaimCatalog.places.first { $0.id == "go-build" }!
        let forged = ReclaimCatalog.Candidate(
            place: goBuild, url: home.appendingPathComponent("outside"))
        #expect(throws: ReclaimCatalog.DeleteError.self) {
            try ReclaimCatalog.deleteNow(forged, home: home)
        }
        #expect(fm.fileExists(atPath: home.appendingPathComponent("outside/keep").path))

        // A place that is a symlink pointing outside home is refused.
        let elsewhere = fm.temporaryDirectory.appendingPathComponent(
            "pathem-elsewhere-\(UUID().uuidString)")
        try write(10, elsewhere.appendingPathComponent("precious"))
        defer { try? fm.removeItem(at: elsewhere) }
        try fm.removeItem(at: home.appendingPathComponent("Library/Caches/go-build"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent("Library/Caches/go-build"),
            withDestinationURL: elsewhere)
        let linked = ReclaimCatalog.Candidate(
            place: goBuild, url: home.appendingPathComponent("Library/Caches/go-build"))
        #expect(throws: ReclaimCatalog.DeleteError.self) {
            try ReclaimCatalog.deleteNow(linked, home: home)
        }
        #expect(fm.fileExists(atPath: elsewhere.appendingPathComponent("precious").path))
    }

    /// Caches hold read-only folders (Go and Cargo write them). Delete Now must clear them,
    /// and when something truly cannot go it must remove the rest and name what is left.
    @Test func deleteNowClearsReadOnlyFoldersAndReportsWhatIsLeft() throws {
        let home = try home()
        let fm = FileManager.default
        let place = home.appendingPathComponent("Library/Caches/go-build")
        let locked = place.appendingPathComponent("ro/inner")
        let stuck = place.appendingPathComponent("stuck/file")
        defer {
            _ = stuck.path.withCString { chflags($0, 0) }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: home)
        }
        try write(10, locked.appendingPathComponent("a"))
        try write(10, place.appendingPathComponent("plain/b"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try fm.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: locked.deletingLastPathComponent().path)
        // Control: the plain FileManager delete, which this replaced, fails on this tree.
        #expect(throws: (any Error).self) {
            try fm.removeItem(at: place.appendingPathComponent("ro"))
        }
        let candidate = ReclaimCatalog.candidates(home: home).first { $0.place.id == "go-build" }!
        try ReclaimCatalog.deleteNow(candidate, home: home)
        #expect(try fm.contentsOfDirectory(atPath: place.path).isEmpty)

        // A file inside a folder that is put back read-only by the system (here: an
        // append-only parent, which chmod cannot override) stays; everything else goes.
        try write(10, stuck)
        try write(10, place.appendingPathComponent("plain/c"))
        let parent = stuck.deletingLastPathComponent().path
        #expect(parent.withCString { chflags($0, UInt32(UF_APPEND)) } == 0)
        defer { _ = parent.withCString { chflags($0, 0) } }
        do {
            try ReclaimCatalog.deleteNow(candidate, home: home)
            Issue.record("expected an incomplete delete")
        } catch let ReclaimCatalog.DeleteError.incomplete(left, firstPath, reason) {
            #expect(left == 1)
            #expect(firstPath.hasSuffix("stuck/file"))
            #expect(!reason.isEmpty)
        }
        #expect(fm.fileExists(atPath: stuck.path))
        #expect(!fm.fileExists(atPath: place.appendingPathComponent("plain").path))
    }

    /// Two deletes of the same place at once (a second click during a long delete, or a
    /// build tool cleaning its own folders) must not report the other's work as a failure.
    @Test func concurrentDeletesOfOnePlaceBothSucceed() async throws {
        let home = try home()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let place = home.appendingPathComponent("Library/Caches/go-build")
        for index in 0..<4000 {
            try write(1, place.appendingPathComponent("d\(index % 40)/e\(index % 25)/f\(index)"))
        }
        let candidate = ReclaimCatalog.candidates(home: home).first { $0.place.id == "go-build" }!
        let errors = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        try ReclaimCatalog.deleteNow(candidate, home: home)
                        return nil
                    } catch { return "\(error)" }
                }
            }
            var found: [String] = []
            for await error in group { if let error { found.append(error) } }
            return found
        }
        #expect(errors.isEmpty, "\(errors)")
        #expect(try fm.contentsOfDirectory(atPath: place.path).isEmpty)
    }
}
