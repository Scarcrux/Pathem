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
}
