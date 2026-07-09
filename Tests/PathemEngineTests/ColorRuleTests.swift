import Foundation
import Testing

@testable import PathemEngine

@Suite struct ColorRuleTests {
    @Test func extensionMatch() {
        let rule = ColorRule(field: .ext, op: .isAnyOf, value: "tmp, log,.bak")
        #expect(rule.matches(name: "core.log", isDirectory: false, size: 10))
        #expect(rule.matches(name: "old.BAK", isDirectory: false, size: 10))  // case-insensitive
        #expect(!rule.matches(name: "notes.txt", isDirectory: false, size: 10))
        #expect(!rule.matches(name: "logs", isDirectory: true, size: 0))  // a folder has no extension
    }

    @Test func nameOps() {
        #expect(
            ColorRule(field: .name, op: .contains, value: "draft")
                .matches(name: "My Draft v2.docx", isDirectory: false, size: 1))
        #expect(
            ColorRule(field: .name, op: .beginsWith, value: "IMG_")
                .matches(name: "img_2201.jpg", isDirectory: false, size: 1))
        #expect(
            ColorRule(field: .name, op: .endsWith, value: ".part")
                .matches(name: "movie.mkv.part", isDirectory: false, size: 1))
    }

    @Test func globMatch() {
        let rule = ColorRule(field: .name, op: .matches, value: "*.min.*")
        #expect(rule.matches(name: "app.min.js", isDirectory: false, size: 1))
        #expect(!rule.matches(name: "app.js", isDirectory: false, size: 1))
        #expect(Glob.match(pattern: "a?c*", name: "abcdef"))
        #expect(!Glob.match(pattern: "a?c", name: "abcd"))
        #expect(Glob.match(pattern: "*", name: "anything"))
    }

    @Test func sizeThresholdsInMB() {
        let big = ColorRule(field: .size, op: .greaterThan, value: "1000")  // > 1000 MB
        #expect(big.matches(name: "huge.iso", isDirectory: false, size: 2_000_000_000))
        #expect(!big.matches(name: "small.txt", isDirectory: false, size: 5))
        let tiny = ColorRule(field: .size, op: .lessThan, value: "0.001")  // < 1 KB
        #expect(tiny.matches(name: "note", isDirectory: false, size: 200))
    }

    @Test func kindFolderVsFile() {
        #expect(
            ColorRule(field: .kind, op: .isAnyOf, value: "folder")
                .matches(name: "Projects", isDirectory: true, size: 0))
        #expect(
            !ColorRule(field: .kind, op: .isAnyOf, value: "folder")
                .matches(name: "file.txt", isDirectory: false, size: 0))
        #expect(
            ColorRule(field: .kind, op: .isAnyOf, value: "file")
                .matches(name: "file.txt", isDirectory: false, size: 0))
    }

    @Test func firstEnabledMatchWins() {
        let rules = ColorRules(rules: [
            ColorRule(name: "disabled", enabled: false, field: .ext, op: .isAnyOf, value: "txt", colorHex: "#111111"),
            ColorRule(name: "logs", field: .ext, op: .isAnyOf, value: "txt", colorHex: "#FF0000"),
            ColorRule(name: "also txt", field: .ext, op: .isAnyOf, value: "txt", colorHex: "#00FF00"),
        ])
        let hit = rules.match(name: "a.txt", isDirectory: false, size: 1)
        #expect(hit?.colorHex == "#FF0000")  // skips the disabled rule, takes the first enabled
        #expect(rules.match(name: "a.pdf", isDirectory: false, size: 1) == nil)
    }

    @Test func roundTripAndTolerantDecode() throws {
        let rules = ColorRules(rules: [ColorRule(name: "big", field: .size, op: .greaterThan, value: "500", colorHex: "#FF0000", bold: true)])
        let decoded = try JSONDecoder().decode(ColorRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
        // An older/partial rule object still decodes with defaults.
        let partial = #"{"rules":[{"value":"txt"}]}"#
        let d = try JSONDecoder().decode(ColorRules.self, from: Data(partial.utf8))
        #expect(d.rules.first?.field == .ext && d.rules.first?.enabled == true)
    }
}
