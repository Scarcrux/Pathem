import Foundation
import Testing

@testable import PathemEngine

@Suite struct PreferencesTests {
    @Test func legacySystemIconFollowsThemeButExplicitCurrentOverrideSurvives() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"iconSetName":"System"}"#.utf8).write(to: file)
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(Preferences.self, from: Data(contentsOf: file))
        #expect(legacy.iconSetName.isEmpty)

        let current = Preferences(iconSetName: "System")
        let decoded = try decoder.decode(Preferences.self, from: JSONEncoder().encode(current))
        #expect(decoded.iconSetName == "System")
    }

    /// A preferences file written while the retired built-in Dracula was applied. The palette
    /// and styles are stored by value, so they must decode unchanged; only the name is dropped,
    /// leaving the unnamed custom state instead of pointing at a preset that no longer exists.
    @Test func retiredDraculaSelectionBecomesCustomWithTheSameLook() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let older = #"""
            {"themeName":"Dracula","appearance":"dark","accentColorHex":"#BD93F9",
             "windowTintHex":"#282A36","iconSetName":"",
             "themeStyles":{"folder":"Plum","fileIcons":"Vivid","toolbar":"Circled"}}
            """#
        try Data(older.utf8).write(to: file)
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))

        #expect(decoded.appearance == .dark)
        #expect(decoded.accentColorHex == "#BD93F9")
        #expect(decoded.windowTintHex == "#282A36")
        #expect(decoded.themeStyles == ThemeStyles(.plum, .vivid, .circled))
        #expect(decoded.effectiveThemeStyles == ThemeStyles(.plum, .vivid, .circled))
        #expect(decoded.communityTheme == nil)
        #expect(decoded.themeName.isEmpty, "still names the retired preset")
        #expect(!ThemePreset.presets.contains { $0.name == decoded.themeName })
        // Not a silent fallback to System, and not remapped onto another built-in.
        #expect(ThemePreset(preferences: decoded) != .system)
        #expect(
            ThemePreset.matching(
                accentHex: decoded.accentColorHex, backgroundHex: decoded.windowTintHex,
                appearance: decoded.appearance) == nil)

        // The migrated state is stable across a save and reload.
        let again = try JSONDecoder().decode(
            Preferences.self, from: JSONEncoder().encode(decoded))
        #expect(again == decoded)
    }

    /// A theme the user imported or installed under the same name is theirs and keeps its name.
    @Test func otherThemesNamedDraculaKeepTheirName() throws {
        let imported = #"""
            {"themeName":"Dracula","appearance":"dark","accentColorHex":"#FF79C6",
             "windowTintHex":"#21222C"}
            """#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(imported.utf8))
        #expect(decoded.themeName == "Dracula")
        #expect(decoded.accentColorHex == "#FF79C6")
    }

    @Test func defaultsAreSensible() {
        let prefs = Preferences.default
        #expect(prefs.density == .comfortable)
        #expect(prefs.searchOCR == false)
        #expect(prefs.rowHeight == 24)  // 13 + 11, matches the historical default
        #expect(prefs.sizeFormat == .decimal)  // Finder-style KB/MB by default
        #expect(prefs.dateDisplay == .relative)  // Finder-style "Today at 3:14 PM" by default
        #expect(prefs.dragMovesByDefault)
    }

    @Test func dragDefaultMovesButPreservesExplicitCopyPreference() throws {
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(legacy.dragMovesByDefault)
        for moves in [false, true] {
            let saved = Preferences(dragMovesByDefault: moves)
            let restored = try JSONDecoder().decode(
                Preferences.self, from: JSONEncoder().encode(saved))
            #expect(restored.dragMovesByDefault == moves)
        }
    }

    @Test func downloadSuggestionsRequireExplicitOptIn() throws {
        #expect(!Preferences.default.downloadSuggestionsEnabled)
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(!legacy.downloadSuggestionsEnabled)
        for enabled in [false, true] {
            let prefs = Preferences(downloadSuggestionsEnabled: enabled)
            let restored = try JSONDecoder().decode(
                Preferences.self, from: JSONEncoder().encode(prefs))
            #expect(restored.downloadSuggestionsEnabled == enabled)
        }
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

    @Test func stackPanesVerticallyDefaultsOffAndPersists() throws {
        #expect(Preferences().stackPanesVertically == false)
        let legacy = Data(#"{ "density": "compact" }"#.utf8)
        #expect(
            try JSONDecoder().decode(Preferences.self, from: legacy).stackPanesVertically == false)
        var prefs = Preferences()
        prefs.stackPanesVertically = true
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data).stackPanesVertically == true)
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
