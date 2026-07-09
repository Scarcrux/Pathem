import Foundation
import Testing

@testable import PathemEngine

@Suite struct PreferencesTests {
    @Test func defaultsAreSensible() {
        let prefs = Preferences.default
        #expect(prefs.density == .comfortable)
        #expect(prefs.searchOCR == false)
        #expect(prefs.rowHeight == 24)  // 13 + 11, matches the historical default
        #expect(prefs.sizeFormat == .decimal)  // Finder-style KB/MB by default
        #expect(prefs.dateDisplay == .medium)
    }

    @Test func sizeAndDateFormatsRoundTrip() throws {
        let prefs = Preferences(sizeFormat: .binary, dateDisplay: .relative)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.sizeFormat == .binary)
        #expect(decoded.dateDisplay == .relative)
        // An older prefs.json without the fields decodes to the defaults.
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":13}"#.utf8))
        #expect(old.sizeFormat == .decimal && old.dateDisplay == .medium)
    }

    @Test func startupAndOpenBehaviorRoundTrip() throws {
        let prefs = Preferences(
            newTabLocation: .fixed, fixedStartFolder: "/Users/me/Work", middleClickOpensNewTab: false)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.newTabLocation == .fixed)
        #expect(decoded.fixedStartFolder == "/Users/me/Work")
        #expect(decoded.middleClickOpensNewTab == false)
        // Defaults: last folder, middle-click on.
        #expect(Preferences.default.newTabLocation == .lastFolder)
        #expect(Preferences.default.middleClickOpensNewTab == true)
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
        let prefs = Preferences(
            density: .compact, fontSize: 15, alternatingRows: false, searchOCR: true,
            showFullPathInTitle: true, pathBarAtBottom: true, openConnectionsInNewTab: true,
            calculateFolderSizes: true, compactSidebar: true)
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == prefs)
    }

    @Test func decodesOlderFileWithMissingKeys() throws {
        // A prefs.json from a build before the newer keys existed must still load,
        // defaulting the missing keys instead of failing (which would reset prefs).
        let legacy = """
            { "density": "compact", "fontSize": 15, "alternatingRows": false, "searchOCR": true }
            """
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
        #expect(prefs.density == .compact)
        #expect(prefs.fontSize == 15)
        #expect(prefs.searchOCR == true)
        #expect(prefs.showFullPathInTitle == false)  // defaulted
        #expect(prefs.pathBarAtBottom == true)  // defaulted (Finder-style bottom path bar)
        #expect(prefs.openConnectionsInNewTab == false)  // defaulted
        #expect(prefs.calculateFolderSizes == false)  // defaulted
        #expect(prefs.compactSidebar == false)  // defaulted
        #expect(prefs.instantTooltips == false)  // defaulted
        #expect(prefs.toolbarIconSize == .medium)  // defaulted
        #expect(prefs.hiddenContextItems.isEmpty)  // defaulted
    }

    @Test func instantTooltipsDefaultsOffAndRoundTrips() throws {
        #expect(Preferences.default.instantTooltips == false)
        var prefs = Preferences.default
        prefs.instantTooltips = true
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data).instantTooltips == true)
    }
}
