import Foundation
import Testing

@testable import PathemEngine

struct ExternalThemeImportTests {
    @Test func vscodeAcceptsJSONCAndMapsOpaqueRoles() throws {
        let json = """
            {
                // VS Code export
                "type": "dark",
                "colors": {
                    "editor.background": "#123F",
                    "focusBorder": "#2220",
                    "activityBarBadge.background": "#abcdefFF",
                },
                "tokenColors": "https://example.invalid/theme"
            }
            """
        let theme = try ExternalThemeImport.vscode(Data(json.utf8), name: "Imported")
        #expect(
            theme
                == ThemePreset(
                    name: "Imported", appearance: .dark,
                    accentHex: "#ABCDEF", backgroundHex: "#112233"))
    }

    @Test func ignoresForeignSettingsAndRejectsNoUsableColors() {
        let json = #"{"include":"local.json","colors":{"focusBorder":"nonsense"}}"#
        #expect(throws: ExternalThemeImport.ImportError.invalidPalette) {
            try ExternalThemeImport.vscode(Data(json.utf8), name: "Empty")
        }
    }

    @Test func itermMapsCompleteANSIAndPreservesOptionalRoles() throws {
        let color: [String: Any] = [
            "Red Component": 1.0, "Green Component": 0.5, "Blue Component": 0.0,
            "Color Space": "sRGB",
        ]
        var root: [String: Any] = [
            "Foreground Color": color,
            "Background Color": [
                "Red Component": true, "Green Component": 0.5, "Blue Component": 0.0,
            ],
        ]
        for index in 0..<15 { root["Ansi \(index) Color"] = color }
        let partialData = try PropertyListSerialization.data(
            fromPropertyList: root, format: .xml, options: 0)
        let partial = try ExternalThemeImport.iterm(partialData, name: "Orange")
        #expect(partial.foreground == "#FF8000")
        #expect(partial.background == nil)
        #expect(partial.cursor == nil)
        #expect(partial.ansi == nil)
        root["Ansi 15 Color"] = color
        let completeData = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)
        #expect(
            try ExternalThemeImport.iterm(completeData, name: "Orange").ansi
                == Array(repeating: "#FF8000", count: 16))
    }
}
