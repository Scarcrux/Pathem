import Foundation
import Testing

@testable import PathemEngine

@Suite struct PathSuggesterTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-suggest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    @Test func absoluteExistingPathResolves() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = PathSuggester.resolve(dir.path, base: URL(fileURLWithPath: "/"))
        #expect(result.kind == .absolute)
        #expect(result.exists)
        #expect(result.existing?.standardizedFileURL == dir)
    }

    @Test func relativePathResolvesAgainstBase() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let result = PathSuggester.resolve("inner", base: dir)
        #expect(result.kind == .relative)
        #expect(result.existing?.standardizedFileURL == sub.standardizedFileURL)
    }

    @Test func tildeIsTreatedAsAbsolute() {
        let result = PathSuggester.resolve("~/Documents", base: URL(fileURLWithPath: "/tmp"))
        #expect(result.kind == .absolute)  // expands to the home dir, not /tmp/~/Documents
        #expect(result.requested.path.hasPrefix(NSHomeDirectory()))
    }

    @Test func suggestsClosestPathForATypo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Desktop"), withIntermediateDirectories: true)

        // "Desktp" is one deletion from "Desktop".
        let result = PathSuggester.resolve(dir.appendingPathComponent("Desktp").path, base: dir)
        #expect(!result.exists)
        #expect(result.suggestion?.lastPathComponent == "Desktop")
    }

    @Test func correctsAnIntermediateComponentAndKeepsGoing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Projects/website", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        // Typo in the middle component ("Porjects"); the leaf exists under the fix.
        let result = PathSuggester.resolve(dir.appendingPathComponent("Porjects/website").path, base: dir)
        #expect(result.suggestion?.standardizedFileURL == real.standardizedFileURL)
    }

    @Test func noSuggestionForUnrelatedGarbage() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Desktop"), withIntermediateDirectories: true)

        let result = PathSuggester.resolve(
            dir.appendingPathComponent("qwertyuiop-zzz-9999").path, base: dir)
        #expect(!result.exists)
        #expect(result.suggestion == nil)  // nothing close enough to suggest
    }

    /// A toy embedder so the semantic-fallback path is deterministic without the
    /// on-device model: "pics" and "photos" share a vector, everything else differs.
    private struct StubEmbedder: TextEmbedder {
        var dimension: Int { 2 }
        func embed(_ text: String) -> [Float]? {
            let t = text.lowercased()
            if t.contains("pic") || t.contains("photo") { return [1, 0] }
            return [0, 1]
        }
    }

    @Test func semanticFallbackResolvesAMeaningBasedTypo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Photos"), withIntermediateDirectories: true)

        // "pics" is not spelled close to "Photos" (edit distance is large), so only
        // the semantic model can connect them.
        let editOnly = PathSuggester.resolve(dir.appendingPathComponent("pics").path, base: dir)
        #expect(editOnly.suggestion == nil)  // edit-distance alone can't bridge it

        let withModel = PathSuggester.resolve(
            dir.appendingPathComponent("pics").path, base: dir, embedder: StubEmbedder())
        #expect(withModel.suggestion?.lastPathComponent == "Photos")
    }

    @Test func editDistanceIsCorrect() {
        #expect(PathSuggester.distance("kitten", "sitting") == 3)
        #expect(PathSuggester.distance("desktp", "desktop") == 1)
        #expect(PathSuggester.distance("", "abc") == 3)
        #expect(PathSuggester.distance("same", "same") == 0)
    }
}
