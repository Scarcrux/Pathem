import Foundation
import Testing

@testable import PathemEngine

@Suite struct ChangelogParserTests {
    @Test func parsesVersionsDatesAndNotes() {
        let md = """
            # Pathem changelog

            ## 0.9.0 - 2026-07-26
            - Live Quick Look previews in column and gallery views.
            - A visible update button when a new version is ready.

            ## 0.8.0 - 2026-07-20
            * Native torrent client.
            """
        let entries = ChangelogParser.parse(md)
        #expect(entries.count == 2)
        #expect(entries[0].version == "0.9.0")
        #expect(entries[0].date == "2026-07-26")
        #expect(entries[0].notes.count == 2)
        #expect(entries[0].notes.first == "Live Quick Look previews in column and gallery views.")
        // A "*" bullet is recognized the same as "-".
        #expect(entries[1].version == "0.8.0")
        #expect(entries[1].notes == ["Native torrent client."])
    }

    @Test func headingWithoutDateHasNilDate() {
        let entries = ChangelogParser.parse("## 1.0.0\n- Shipped.")
        #expect(entries.count == 1)
        #expect(entries[0].version == "1.0.0")
        #expect(entries[0].date == nil)
        #expect(entries[0].notes == ["Shipped."])
    }

    @Test func ignoresProseAndStrayBulletsOutsideAnyVersion() {
        let md = """
            # Title
            - a stray bullet before any version heading is ignored

            ## 0.1.0 - 2026-01-01
            Some prose that is not a bullet.
            - Real note.
            """
        let entries = ChangelogParser.parse(md)
        #expect(entries.count == 1)
        #expect(entries[0].notes == ["Real note."])
    }

    @Test func emptyInputYieldsNoEntries() {
        #expect(ChangelogParser.parse("").isEmpty)
    }
}
