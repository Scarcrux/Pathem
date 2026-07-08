import Foundation
import Testing

@testable import PathemEngine

/// The generative calls need Apple Intelligence and are non-deterministic, so only the pure
/// reply-sanitizer is unit-tested here — that's where the parsing/safety logic lives.
@Suite struct AIAssistantTests {
    @Test func keepsACleanName() {
        #expect(AIAssistant.sanitizeSuggestedName("budget-report-2024") == "budget-report-2024")
    }

    @Test func stripsSurroundingQuotesAndBackticks() {
        #expect(AIAssistant.sanitizeSuggestedName("\"quarterly-summary\"") == "quarterly-summary")
        #expect(AIAssistant.sanitizeSuggestedName("`meeting-notes`") == "meeting-notes")
        #expect(AIAssistant.sanitizeSuggestedName("“smart quotes”") == "smart quotes")
    }

    @Test func takesFirstLineOnly() {
        #expect(AIAssistant.sanitizeSuggestedName("invoice-final\nHere is why...") == "invoice-final")
    }

    @Test func stripsLeadingLabel() {
        #expect(AIAssistant.sanitizeSuggestedName("Filename: tax-return-2023") == "tax-return-2023")
        #expect(AIAssistant.sanitizeSuggestedName("Name: résumé") == "résumé")
    }

    @Test func removesPathSeparatorsAndColons() {
        #expect(AIAssistant.sanitizeSuggestedName("a/b:c") == "abc")
    }

    @Test func trimsTrailingPunctuationAndHiddenDot() {
        #expect(AIAssistant.sanitizeSuggestedName("report.") == "report")
        #expect(AIAssistant.sanitizeSuggestedName(".hidden") == "hidden")
    }

    @Test func collapsesWhitespace() {
        #expect(AIAssistant.sanitizeSuggestedName("  my    great   file  ") == "my great file")
    }

    @Test func returnsNilForEmptyOrUnusable() {
        #expect(AIAssistant.sanitizeSuggestedName("") == nil)
        #expect(AIAssistant.sanitizeSuggestedName("   \n  ") == nil)
        #expect(AIAssistant.sanitizeSuggestedName("///") == nil)
    }

    @Test func availabilityIsDefinedEvenWithoutAppleIntelligence() {
        // Whatever this machine reports, the accessor must not trap and reason must be
        // consistent with availability.
        let a = AIAssistant.availability
        #expect((a == .available) == a.reason.isEmpty)
    }
}
