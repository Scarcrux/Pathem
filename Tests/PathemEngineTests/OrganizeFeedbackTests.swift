import Foundation
import Testing

@testable import PathemEngine

@Suite struct OrganizeFeedbackTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pathem-fb-\(UUID().uuidString).json")
    }

    @Test func recordsAndScoresVerdicts() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        OrganizeFeedback.record(.init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .good), to: url)
        OrganizeFeedback.record(.init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .good), to: url)
        OrganizeFeedback.record(.init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .bad), to: url)

        let log = OrganizeFeedback.load(from: url)
        #expect(log.entries.count == 3)
        #expect(log.score(ruleID: "by-kind") == 1)  // 2 good, 1 bad
        #expect(log.score(destination: "PDFs") == 1)
        #expect(log.score(ruleID: "screenshots") == 0)  // no data
    }

    @Test func missingFileLoadsEmpty() {
        let log = OrganizeFeedback.load(from: tempURL())
        #expect(log.entries.isEmpty)
    }

    @Test func malformedFileLoadsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(OrganizeFeedback.load(from: url).entries.isEmpty)
    }
}
