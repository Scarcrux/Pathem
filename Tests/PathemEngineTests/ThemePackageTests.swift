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
        prefs.iconSetName = "example"
        prefs.density = .compact
        ThemePreset.harbor.apply(to: &prefs)

        prefs.appearance = .system
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "#82D4DE",
                    backgroundHex: "#182630"))

        prefs.accentColorHex = ""
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "", backgroundHex: "#182630"))

        prefs.accentColorHex = "#123456"
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "#123456",
                    backgroundHex: "#182630"))

        prefs.windowTintHex = ""
        #expect(
            try export(prefs)
                == ThemePreset(
                    name: "Harbor", appearance: .system, accentHex: "#123456"))

        ThemePreset.system.apply(to: &prefs)
        #expect(try export(prefs) == .system)
        #expect(prefs.iconSetName == "example")
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
            #"{"schemaVersion":2,"name":"Test","appearance":"dark","accent":null,"background":null}"#
        #expect(throws: ThemePackage.ValidationError.unsupportedVersion(2)) {
            try ThemePackage.decode(Data(future.utf8))
        }
        #expect(throws: ThemePackage.ValidationError.tooLarge) {
            try ThemePackage.decode(Data(repeating: 32, count: ThemePackage.maximumBytes + 1))
        }
        let utf16 = try #require(
            future.replacingOccurrences(of: ":2", with: ":1").data(using: .utf16LittleEndian))
        #expect(throws: ThemePackage.ValidationError.invalidDocument) {
            try ThemePackage.decode(utf16)
        }
    }

    private func export(_ prefs: Preferences) throws -> ThemePreset {
        try ThemePackage.decode(ThemePackage.encode(ThemePreset(preferences: prefs)))
    }
}
