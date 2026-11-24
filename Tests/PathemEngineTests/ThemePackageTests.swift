import Foundation
import Testing

@testable import PathemEngine

@Suite struct ThemePackageTests {
    @Test func pilotSamplesRoundTrip() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/themes/Orchard.json")
        let orchard = try ThemePackage.decode(Data(contentsOf: fixture))
        #expect(
            orchard
                == ThemePreset(
                    name: "Orchard", appearance: .light, accentHex: "#2D694F",
                    backgroundHex: "#F5F2E8"))
        for theme in [ThemePreset.system, .harbor, orchard] {
            #expect(try ThemePackage.decode(ThemePackage.encode(theme)) == theme)
        }
    }

    @Test func overridesExportIndependentlyAndReset() throws {
        var prefs = Preferences()
        prefs.iconSetName = ThemeStyles.FileIcons.vivid.rawValue
        prefs.density = .compact
        ThemePreset.harbor.apply(to: &prefs)

        let styles = ThemeStyles(.azure, .vivid, .rounded)
        prefs.appearance = .system
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "#82D4DE",
                    backgroundHex: "#182630", styles: styles))

        prefs.accentColorHex = ""
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "", backgroundHex: "#182630",
                    styles: styles))

        prefs.accentColorHex = "#123456"
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "#123456",
                    backgroundHex: "#182630", styles: styles))

        prefs.windowTintHex = ""
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "#123456", styles: styles))

        ThemePreset.system.apply(to: &prefs)
        #expect(try export(prefs).styles == ThemeStyles(.system, .vivid, .system))
        #expect(prefs.iconSetName == "Vivid")
        #expect(prefs.density == .compact)
    }

    @Test(arguments: [
        #"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":null,"background":null,"toolbar":[]}"#,
        #"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":null}"#,
        #"{"schemaVersion":true,"name":"Test","appearance":"dark","accent":null,"background":null}"#,
        #"{"schemaVersion":1,"name":"   ","appearance":"dark","accent":null,"background":null}"#,
        #"{"schemaVersion":1,"name":"Test","appearance":"automatic","accent":null,"background":null}"#,
        ##"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":"#123456FF","background":null}"##,
        #"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":"+123456","background":null}"#,
        #"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":null,"background":false}"#,
        #"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":null,"background":null} trailing"#,
        #"{"schemaVersion":1,"name":"Test","appearance":"dark","accent":null,"background":null,}"#,
    ])
    func rejectsInvalidDocuments(json: String) {
        #expect(throws: ThemePackage.ValidationError.self) {
            try ThemePackage.decode(Data(json.utf8))
        }
    }

    @Test func rejectsUnsupportedVersionOversizedInputAndUTF16() throws {
        let future =
            #"{"schemaVersion":3,"name":"Test","appearance":"dark","accent":null,"background":null}"#
        #expect(throws: ThemePackage.ValidationError.unsupportedVersion(3)) {
            try ThemePackage.decode(Data(future.utf8))
        }
        #expect(throws: ThemePackage.ValidationError.tooLarge) {
            try ThemePackage.decode(Data(repeating: 32, count: ThemePackage.maximumBytes + 1))
        }
        let utf16 = try #require(
            future.replacingOccurrences(of: ":3", with: ":1").data(using: .utf16LittleEndian))
        #expect(throws: ThemePackage.ValidationError.invalidDocument) {
            try ThemePackage.decode(utf16)
        }
    }

    @Test func completeCatalogAndIndependentSavedOverrides() throws {
        #expect(ThemeStyles.Folder.allCases.count >= 10)
        #expect(ThemeStyles.FileIcons.allCases.count >= 10)
        #expect(ThemeStyles.Toolbar.allCases.count >= 10)
        #expect(ThemePreset.presets.count >= 10)
        for preset in ThemePreset.presets {
            #expect(preset.styles != nil)
            #expect(try ThemePackage.decode(ThemePackage.encode(preset)) == preset)
        }

        let legacyPreferences = Data(#"{"iconSetName":"Blueprint"}"#.utf8)
        var prefs = try JSONDecoder().decode(Preferences.self, from: legacyPreferences)
        ThemePreset.harbor.apply(to: &prefs)
        prefs.folderStyleOverride = .system
        prefs.toolbarStyleOverride = .fine
        #expect(prefs.effectiveThemeStyles == ThemeStyles(.system, .blueprint, .fine))
        prefs.iconSetName = "System"
        #expect(prefs.effectiveThemeStyles == ThemeStyles(.system, .system, .fine))
        prefs.folderStyleOverride = nil
        #expect(prefs.effectiveThemeStyles == ThemeStyles(.azure, .system, .fine))
        prefs.toolbarStyleOverride = nil
        #expect(prefs.effectiveThemeStyles == ThemeStyles(.azure, .system, .rounded))
        prefs.iconSetName = ""
        #expect(prefs.effectiveThemeStyles == ThemePreset.harbor.styles)

        let legacyPalette = ThemePreset(name: "Legacy", appearance: .light, accentHex: "")
        let imported = try ThemePackage.decode(ThemePackage.encode(legacyPalette))
        imported.apply(to: &prefs)
        #expect(prefs.effectiveThemeStyles == ThemePreset.harbor.styles)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored.effectiveThemeStyles == prefs.effectiveThemeStyles)
    }

    @Test func rejectsInvalidCompleteLookBeforeApply() throws {
        let data = try ThemePackage.encode(ThemePreset.harbor)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["folderStyle", "fileIconSet", "toolbarStyle"] {
            var invalid = object
            invalid[field] = "Unknown"
            #expect(throws: ThemePackage.ValidationError.invalidDocument) {
                try ThemePackage.decode(JSONSerialization.data(withJSONObject: invalid))
            }
            invalid.removeValue(forKey: field)
            #expect(throws: ThemePackage.ValidationError.invalidDocument) {
                try ThemePackage.decode(JSONSerialization.data(withJSONObject: invalid))
            }
        }
        object["extra"] = true
        #expect(throws: ThemePackage.ValidationError.invalidDocument) {
            try ThemePackage.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    private func export(_ prefs: Preferences) throws -> ThemePreset {
        var theme = ThemePreset(preferences: prefs)
        theme.styles = prefs.effectiveThemeStyles
        return try ThemePackage.decode(ThemePackage.encode(theme))
    }
}
