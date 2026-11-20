import Foundation
import Testing

@testable import PathemEngine

@Suite struct BatchRenameTests {
    @Test func ruleRoundTripsThroughCodable() throws {
        // Saved presets persist a RenameRule as JSON, so its Codable conformance must round-trip.
        let rule = RenameRule(
            find: "a", replace: "b", useRegex: true, prefix: "{date}-", suffix: "_x",
            caseMode: .title, includeExtension: true, counterStart: 5, counterStep: 2,
            counterPadding: 3)
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(RenameRule.self, from: data) == rule)
    }

    @Test func expandsParentAndDateTokens() {
        let rule = RenameRule(prefix: "{parent}-{date}-")
        // 1_600_000_000 is 2020-09-13 (12:26 UTC); the month/day are stable across US time zones.
        let context = RenameContext(
            modified: Date(timeIntervalSince1970: 1_600_000_000), parent: "Trip")
        let name = BatchRename.newName(for: "IMG.jpg", index: 0, rule: rule, context: context)
        #expect(name.hasPrefix("Trip-2020-09-13-"))
        #expect(name.hasSuffix("-IMG.jpg"))
    }

    @Test func expandsCustomDateFormatAndExif() {
        let rule = RenameRule(prefix: "{exif:yyyyMMdd}_")
        let context = RenameContext(exifTaken: Date(timeIntervalSince1970: 1_600_000_000))
        let name = BatchRename.newName(for: "photo.heic", index: 0, rule: rule, context: context)
        #expect(name.hasPrefix("20200913_"))
        #expect(name.hasSuffix("_photo.heic"))
    }

    @Test func extTokenAndUnknownTokenToEmpty() {
        // {ext} comes from the original; an unknown token expands to nothing.
        #expect(
            BatchRename.newName(for: "a.txt", index: 0, rule: RenameRule(prefix: "[{ext}]"))
                == "[txt]a.txt")
        #expect(
            BatchRename.newName(for: "a.txt", index: 0, rule: RenameRule(prefix: "{bogus}x-"))
                == "x-a.txt")
        // No braces: the prefix is used verbatim (no token machinery runs).
        #expect(
            BatchRename.newName(for: "a.txt", index: 0, rule: RenameRule(prefix: "plain-"))
                == "plain-a.txt")
    }

    @Test func findReplacePreservesExtension() {
        let rule = RenameRule(find: "draft", replace: "final")
        #expect(BatchRename.newName(for: "draft-1.txt", index: 0, rule: rule) == "final-1.txt")
        // extension untouched even if it contains the find string
        #expect(BatchRename.newName(for: "a.draft", index: 0, rule: rule) == "a.draft")
    }

    @Test func includeExtensionTouchesWholeName() {
        let rule = RenameRule(find: "draft", replace: "final", includeExtension: true)
        #expect(BatchRename.newName(for: "a.draft", index: 0, rule: rule) == "a.final")
    }

    @Test func regexReplaceWithTemplate() {
        let rule = RenameRule(find: #"(\d+)"#, replace: "[$1]", useRegex: true)
        #expect(BatchRename.newName(for: "img12.png", index: 0, rule: rule) == "img[12].png")
    }

    @Test func caseModes() {
        #expect(
            BatchRename.newName(for: "My File.TXT", index: 0, rule: RenameRule(caseMode: .lower))
                == "my file.TXT")
        #expect(
            BatchRename.newName(for: "my file.txt", index: 0, rule: RenameRule(caseMode: .upper))
                == "MY FILE.txt")
        #expect(
            BatchRename.newName(for: "my file.txt", index: 0, rule: RenameRule(caseMode: .title))
                == "My File.txt")
    }

    @Test func prefixSuffixAroundBaseOnly() {
        let rule = RenameRule(prefix: "x_", suffix: "_y")
        #expect(BatchRename.newName(for: "name.txt", index: 0, rule: rule) == "x_name_y.txt")
    }

    @Test func counterFillsHashRuns() {
        let rule = RenameRule(prefix: "shot-", counterStart: 1, counterPadding: 1)
        // a '#' run is padded to its own length; index advances the counter
        let withHash = RenameRule(prefix: "shot-###-", counterStart: 8, counterStep: 1)
        #expect(BatchRename.newName(for: "a.jpg", index: 0, rule: withHash) == "shot-008-a.jpg")
        #expect(BatchRename.newName(for: "b.jpg", index: 2, rule: withHash) == "shot-010-b.jpg")
        // no '#': appended, padded to counterPadding
        #expect(BatchRename.newName(for: "a.jpg", index: 0, rule: rule) == "shot-a1.jpg")
    }

    @Test func dotfileHasNoExtension() {
        let rule = RenameRule(prefix: "x_")
        #expect(BatchRename.newName(for: ".gitignore", index: 0, rule: rule) == "x_.gitignore")
    }

    @Test func planFlagsDuplicateAndClobberCollisions() {
        // Two different files collapse to the same name -> collision.
        let dup = BatchRename.plan(RenameRule(find: "a", replace: "b"), names: ["a", "b"])
        #expect(dup.hasCollisions)
        #expect(dup.collisions.contains("b"))

        // Renaming onto an existing file that is not in the rename set -> collision.
        let clobber = BatchRename.plan(
            RenameRule(find: "a", replace: "b"), names: ["a.txt"], existing: ["a.txt", "b.txt"])
        #expect(clobber.collisions.contains("b.txt"))

        // A clean rename has no collisions.
        let clean = BatchRename.plan(
            RenameRule(prefix: "z_"), names: ["a.txt", "b.txt"], existing: ["a.txt", "b.txt"])
        #expect(!clean.hasCollisions)
    }

    @Test func rejectsRenameThatEscapesTheFolder() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("pathem-rename-escape-\(UUID())")
        let folder = scratch.appendingPathComponent("items")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let source = folder.appendingPathComponent("item")
        try Data("fixture".utf8).write(to: source)
        let plan = BatchRename.plan(RenameRule(prefix: "../"), names: ["item"])
        #expect(plan.hasCollisions)
        let outcome = BatchRename.perform(in: folder, pairs: plan.pairs)
        #expect(!outcome.failures.isEmpty)
        #expect(fm.fileExists(atPath: source.path))
        #expect(!fm.fileExists(atPath: scratch.appendingPathComponent("item").path))
    }

    @Test func previewFlagsCaseAndNormalizationCollisionsOnTheVolume() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("pathem-case-rename-\(UUID())")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        guard
            try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames == false
        else {
            print("Skipping: scratch volume is not known case-insensitive")
            return
        }
        try Data().write(to: folder.appendingPathComponent("draft"))
        try Data().write(to: folder.appendingPathComponent("CAFÉ"))
        let existing = Set(try fm.contentsOfDirectory(atPath: folder.path))
        let plan = BatchRename.plan(
            RenameRule(find: "draft", replace: "cafe\u{0301}"),
            names: ["draft"], existing: existing,
            caseSensitive: BatchRename.supportsCaseSensitiveNames(in: folder))
        #expect(plan.hasCollisions)
    }

    @Test func performRenamesOnDisk() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-rename-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try "B".data(using: .utf8)!.write(to: dir.appendingPathComponent("b.txt"))

        let outcome = BatchRename.perform(
            in: dir,
            pairs: [RenamePair(original: "a.txt", renamed: "c.txt")])
        #expect(outcome.failures.isEmpty)
        #expect(outcome.renamed == 1)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("c.txt").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    }

    @Test func performSurvivesASwap() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-swap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "A".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.txt"))
        try "B".data(using: .utf8)!.write(to: dir.appendingPathComponent("b.txt"))

        // a <-> b swap; two-phase temps make this safe.
        let outcome = BatchRename.perform(
            in: dir,
            pairs: [
                RenamePair(original: "a.txt", renamed: "b.txt"),
                RenamePair(original: "b.txt", renamed: "a.txt"),
            ])
        #expect(outcome.failures.isEmpty)
        #expect(outcome.renamed == 2)
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "B")
        #expect(try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8) == "A")
        let inverse = outcome.performed.map {
            RenamePair(original: $0.renamed, renamed: $0.original)
        }
        let restored = BatchRename.perform(in: dir, pairs: inverse)
        #expect(restored.failures.isEmpty)
        #expect(restored.renamed == 2)
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "A")
        #expect(try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8) == "B")
    }
}
