import Foundation
import Testing

@testable import PathemEngine

@Suite struct ExtensionManifestTests {
    @Test func fullManifestRoundTrips() throws {
        let manifest = ExtensionManifest(
            id: "com.acme.pathem.superzip", name: "SuperZip", version: "1.2.0",
            minHostVersion: "0.8.0", teamID: "ABCDE12345", executable: "helper",
            contributes: .init(
                commands: [.init(id: "zip", title: "Super Zip", handler: "doZip")],
                columns: [.init(id: "ratio", title: "Ratio", handler: "ratio")],
                viewers: [
                    .init(id: "peek", title: "Peek", utis: ["public.zip-archive"], handler: "peek")
                ],
                menuItems: [.init(command: "zip", menu: "file")],
                keybindings: [.init(command: "zip", chord: "cmd+shift+z")],
                themes: [.init(id: "midnight", name: "Midnight", file: "themes/midnight.json")]))
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(ExtensionManifest.self, from: data) == manifest)
    }

    @Test func partialManifestDefaultsMissingSections() throws {
        // A manifest with no "contributes" and only some sections must still decode, with
        // the missing arrays defaulting to empty rather than failing the whole parse.
        let json = """
            { "id": "com.acme.pathem.mini", "name": "Mini", "version": "1.0.0",
              "executable": "mini", "contributes": { "commands": [
                { "id": "hi", "title": "Hi", "handler": "hi" } ] } }
            """
        let m = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        #expect(m.contributes.commands.count == 1)
        #expect(m.contributes.columns.isEmpty)
        #expect(m.contributes.themes.isEmpty)
        #expect(m.teamID == nil)
        #expect(m.minHostVersion == nil)
    }

    @Test func jsonValueRoundTripsAllCases() throws {
        let value: JSONValue = .object([
            "n": .null, "b": .bool(true), "i": .number(3), "f": .number(3.5),
            "s": .string("hi"), "a": .array([.number(1), .string("x")]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func requestResponseRoundTrip() throws {
        let request = ExtensionProtocol.Request(
            handler: "wordCount", arguments: ["path": .string("/tmp/a.txt")],
            context: .init(folder: "/tmp", selection: ["/tmp/a.txt"]))
        let line = try ExtensionProtocol.encodeLine(request)
        #expect(line.last == 0x0A)  // newline-framed
        let decoded = try JSONDecoder().decode(
            ExtensionProtocol.Request.self, from: line.dropLast())
        #expect(decoded == request)

        let response = ExtensionProtocol.Response.success(.number(42))
        let parsed = try ExtensionProtocol.decodeResponse(
            try JSONEncoder().encode(response) + Data("\n".utf8))
        #expect(parsed == response)
    }

    @Test func decodeResponseTakesFirstNonEmptyLine() throws {
        // Helpers may print blank lines or trailing noise; take the first real line.
        let stdout = Data("\n{\"ok\":true,\"result\":\"pong\"}\ntrailing\n".utf8)
        let r = try ExtensionProtocol.decodeResponse(stdout)
        #expect(r.ok)
        #expect(r.result == .string("pong"))
    }

    @Test func decodeResponseThrowsOnNoOutput() {
        #expect(throws: ExtensionProtocol.MalformedResponse.self) {
            try ExtensionProtocol.decodeResponse(Data("   \n\n".utf8))
        }
    }

    @Test func rejectsDeepAndOversizedProtocolInput() {
        let deep = Data(
            (String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)
        #expect(throws: ExtensionProtocol.MalformedResponse.self) {
            try ExtensionProtocol.checkJSON(deep)
        }
        #expect(throws: ExtensionProtocol.MalformedResponse.self) {
            try ExtensionProtocol.decodeResponse(
                Data(repeating: 0x20, count: ExtensionProtocol.maximumBytes + 1))
        }
    }

    @Test func validationRejectsBadManifests() {
        func expectInvalid(_ m: ExtensionManifest) {
            #expect(throws: ExtensionHost.ExtensionError.self) { try ExtensionHost.validate(m) }
        }
        expectInvalid(.init(id: "noDots", name: "X", version: "1", executable: "h"))
        expectInvalid(.init(id: "com.a.b", name: "", version: "1", executable: "h"))
        expectInvalid(.init(id: "com.a.b", name: "X", version: "1", executable: "/abs/path"))
        expectInvalid(.init(id: "com.a.b", name: "X", version: "1", executable: "../escape"))
        // A well-formed one passes.
        #expect(throws: Never.self) {
            try ExtensionHost.validate(
                .init(id: "com.a.b", name: "X", version: "1", executable: "h"))
        }
    }

    @Test func versionComparison() {
        #expect(ExtensionHost.versionAtLeast("0.8.0", "0.8.0"))
        #expect(ExtensionHost.versionAtLeast("0.9.0", "0.8.0"))
        #expect(ExtensionHost.versionAtLeast("1.0", "0.8.0"))
        #expect(!ExtensionHost.versionAtLeast("0.7.9", "0.8.0"))
        #expect(ExtensionHost.versionAtLeast("0.8", "0.8.0"))  // missing patch reads as 0
    }
}
