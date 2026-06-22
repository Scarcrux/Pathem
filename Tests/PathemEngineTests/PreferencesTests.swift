import Foundation
import Testing

@testable import PathemEngine

@Suite struct PreferencesTests {
    @Test func defaultsAreSensible() {
        let prefs = Preferences.default
        #expect(prefs.density == .comfortable)
        #expect(prefs.searchOCR == false)
        #expect(prefs.rowHeight == 24)  // 13 + 11, matches the historical default
    }

    @Test func compactIsShorter() {
        let compact = Preferences(density: .compact, fontSize: 13)
        let comfortable = Preferences(density: .comfortable, fontSize: 13)
        #expect(compact.rowHeight < comfortable.rowHeight)
        #expect(compact.rowHeight == 19)
    }

    @Test func rowHeightTracksFontSize() {
        #expect(Preferences(density: .comfortable, fontSize: 16).rowHeight == 27)
    }

    @Test func codableRoundTrip() throws {
        let prefs = Preferences(density: .compact, fontSize: 15, alternatingRows: false, searchOCR: true)
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == prefs)
    }
}
