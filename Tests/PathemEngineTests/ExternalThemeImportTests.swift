import Foundation
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

struct ExternalThemeImportTests {
    @Test func unterminatedCommentsFailInBoundedTime() throws {
        let input = Data(String(repeating: "/*x", count: 5500).utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try input.write(to: file)
        let data = try Data(contentsOf: file)
        let start = ContinuousClock.now
        #expect(throws: (any Error).self) {
            try ExternalThemeImport.vscode(data, name: "Invalid")
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    // The import panel filters by content type, so each offered extension must resolve to a
    // type that a real file with that extension conforms to.
    @Test func importPanelTypesAcceptEveryOfferedExtension() throws {
        #expect(ExternalThemeImport.fileExtensions == ["json", "jsonc", "itermcolors"])
        let allowed = ExternalThemeImport.fileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        #expect(allowed.count == ExternalThemeImport.fileExtensions.count)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Night.json", "Night.jsonc", "Night.JSONC", "Night.itermcolors"] {
            let file = folder.appendingPathComponent(name)
            try Data("{ /* VS Code */ \"type\": \"dark\", \"colors\": {} }".utf8).write(to: file)
            let type = try #require(try file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(allowed.contains { type.conforms(to: $0) }, "\(name) resolves to \(type)")
        }
    }

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
