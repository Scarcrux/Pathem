import Foundation
import Testing

@testable import PathemEngine

@Suite struct AutomationRuleTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ name: String, in dir: URL, daysOld: Double = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -daysOld * 86_400)], ofItemAtPath: url.path)
        return url
    }

    @Test func matchesByExtensionAndKind() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try makeFile("report.pdf", in: dir)
        let png = try makeFile("photo.png", in: dir)

        let extRule = AutomationRule(folderPath: dir.path, ext: "pdf", action: .trash)
        #expect(AutomationEngine.matches(extRule, file: pdf))
        #expect(!AutomationEngine.matches(extRule, file: png))

        let kindRule = AutomationRule(folderPath: dir.path, kind: .image, action: .trash)
        #expect(AutomationEngine.matches(kindRule, file: png))
        #expect(!AutomationEngine.matches(kindRule, file: pdf))
    }

    @Test func matchesByAgeAndNameAndDisabled() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try makeFile("invoice-old.pdf", in: dir, daysOld: 40)
        let fresh = try makeFile("invoice-new.pdf", in: dir, daysOld: 1)

        let ageRule = AutomationRule(folderPath: dir.path, olderThanDays: 30, action: .trash)
        #expect(AutomationEngine.matches(ageRule, file: old))
        #expect(!AutomationEngine.matches(ageRule, file: fresh))

        let nameRule = AutomationRule(folderPath: dir.path, nameContains: "invoice", action: .trash)
        #expect(AutomationEngine.matches(nameRule, file: old))

        var disabled = nameRule
        disabled.enabled = false
        #expect(!AutomationEngine.matches(disabled, file: old))
    }

    @Test func moveActionFilesTheMatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try makeFile("statement.pdf", in: dir)
        let dest = dir.appendingPathComponent("Filed")
        let rule = AutomationRule(
            folderPath: dir.path, ext: "pdf", action: .move, destinationPath: dest.path)

        let outcomes = AutomationEngine.run([rule], in: dir)
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.success == true)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("statement.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: pdf.path))
    }

    @Test func tagActionAddsTheTag() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile("keep.txt", in: dir)
        let rule = AutomationRule(folderPath: dir.path, ext: "txt", action: .tag, tag: "Automated")
        _ = AutomationEngine.apply(rule, to: file)
        #expect(FileTags.tags(of: file).contains { $0.name == "Automated" })
    }
}
