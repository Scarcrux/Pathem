import Foundation
import Testing

@testable import PathemEngine

@Suite struct OrganizeFeedbackTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-fb-\(UUID().uuidString).json")
    }

    @Test func recordsAndScoresVerdicts() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        OrganizeFeedback.record(
            .init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .good), to: url)
        OrganizeFeedback.record(
            .init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .good), to: url)
        OrganizeFeedback.record(
            .init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .bad), to: url)

        let log = OrganizeFeedback.load(from: url)
        #expect(log.entries.count == 3)
        // Explicit verdicts weigh double: 2 good (+4) and 1 bad (-2) net to +2.
        #expect(log.score(ruleID: "by-kind") == 2)
        #expect(log.score(ruleID: "by-kind", ext: "pdf") == 2)
        #expect(log.score(destination: "PDFs") == 2)
        #expect(log.score(ruleID: "screenshots") == 0)  // no data
    }

    @Test func impliedAcceptSkipWeighWeaker() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        OrganizeFeedback.record(
            [
                .init(ruleID: "by-kind", destination: "Images", ext: "png", verdict: .applied),
                .init(ruleID: "by-kind", destination: "Images", ext: "png", verdict: .applied),
                .init(ruleID: "by-kind", destination: "Images", ext: "png", verdict: .skipped),
            ], to: url)
        // applied +1 each, skipped -1: 2 - 1 = +1.
        #expect(OrganizeFeedback.load(from: url).score(ruleID: "by-kind", ext: "png") == 1)
    }

    @Test func confidenceBiasIsBoundedAndSigned() {
        var log = OrganizeFeedback()
        // A pile of positive signals saturates at the +0.35 cap.
        log.entries = Array(
            repeating: .init(ruleID: "installer", destination: nil, ext: "dmg", verdict: .good),
            count: 20)
        #expect(log.confidenceBias(ruleID: "installer", ext: "dmg", destination: nil) == 0.35)
        // Negative signals go the other way.
        log.entries = Array(
            repeating: .init(ruleID: "by-kind", destination: "PDFs", ext: "pdf", verdict: .skipped),
            count: 20)
        #expect(log.confidenceBias(ruleID: "by-kind", ext: "pdf", destination: "PDFs") == -0.35)
        // No data means no nudge.
        #expect(
            OrganizeFeedback().confidenceBias(ruleID: "by-kind", ext: "pdf", destination: "PDFs")
                == 0)
    }

    @Test func preferredDestinationTracksMostRecentReroute() {
        var log = OrganizeFeedback()
        log.entries = [
            .init(
                ruleID: "by-kind", destination: "Finance", ext: "pdf", verdict: .routed,
                destinationPath: "/fixture/home/Documents/Finance"),
            .init(
                ruleID: "by-kind", destination: "Taxes", ext: "pdf", verdict: .routed,
                destinationPath: "/fixture/home/Documents/Taxes"),
        ]
        // Most recent correction wins.
        #expect(
            log.preferredDestinationPath(ruleID: "by-kind", ext: "pdf")
                == "/fixture/home/Documents/Taxes")
        #expect(log.preferredDestinationPath(ruleID: "by-kind", ext: "png") == nil)  // different type
        #expect(log.preferredDestinationPath(ruleID: "screenshots", ext: "pdf") == nil)  // different rule
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
