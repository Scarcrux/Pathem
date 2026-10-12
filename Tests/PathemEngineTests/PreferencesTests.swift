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
        #expect(prefs.dateDisplay == .relative)  // Finder-style "Today at 3:14 PM" by default
    }

    @Test func sizeAndDateFormatsRoundTrip() throws {
        let prefs = Preferences(sizeFormat: .binary, dateDisplay: .relative)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.sizeFormat == .binary)
        #expect(decoded.dateDisplay == .relative)
        // An older prefs.json without the fields decodes to the defaults.
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":13}"#.utf8))
        #expect(old.sizeFormat == .decimal && old.dateDisplay == .relative)
    }

    @Test func commanderStatusAndNewItemRoundTrip() throws {
        let prefs = Preferences(
            commanderCommands: ["a", "b", "c", "d", "e", "f"],
            statusShowItemCount: false, statusShowSize: true, statusShowFreeSpace: true,
            newFolderName: "New Directory", newFileName: "scratch.txt", newTabAtEnd: false)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.commanderCommands == ["a", "b", "c", "d", "e", "f"])
        #expect(decoded.statusShowItemCount == false && decoded.statusShowFreeSpace == true)
        #expect(decoded.newFolderName == "New Directory" && decoded.newFileName == "scratch.txt")
        #expect(decoded.newTabAtEnd == false)
        // Defaults: standard names, tabs at end, status shows count+size.
        let d = Preferences.default
        #expect(d.newFolderName == "untitled folder" && d.newTabAtEnd == true)
        #expect(d.statusShowItemCount && d.statusShowSize && !d.statusShowFreeSpace)
        #expect(d.commanderCommands.isEmpty)  // empty = the orthodox defaults
    }

    @Test func defaultViewAndSortRoundTrip() throws {
        let prefs = Preferences(
            defaultViewMode: .icon, defaultSortKey: .date, defaultSortAscending: false)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.defaultViewMode == .icon)
        #expect(decoded.defaultFormat.sortKey == .date)
        #expect(decoded.defaultFormat.ascending == false)
        #expect(decoded.defaultFormat.viewMode == .icon)
        // Defaults reproduce the historical fallback (list, name, ascending).
        #expect(Preferences.default.defaultFormat == ViewFormat.default)
    }

    @Test func startupAndOpenBehaviorRoundTrip() throws {
        let prefs = Preferences(
            newTabLocation: .fixed, fixedStartFolder: "/fixture/home/Work",
            middleClickOpensNewTab: false)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.newTabLocation == .fixed)
        #expect(decoded.fixedStartFolder == "/fixture/home/Work")
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
        #expect(prefs.toolbarIconSize == .large)  // defaulted (bumped from .medium for legibility)
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
