import Foundation
import Testing

@testable import PathemEngine

@Suite struct MacrosTests {
    @Test func decodesAndIsTolerant() throws {
        let json = #"{"macros":[{"name":"Tidy","commands":["view.flatView","view.filter"]},{"commands":["x"]}]}"#
        let set = try JSONDecoder().decode(Macros.self, from: Data(json.utf8))
        #expect(set.macros.count == 2)
        #expect(set.macros[0].name == "Tidy")
        #expect(set.macros[0].commands == ["view.flatView", "view.filter"])
        #expect(set.macros[1].name == "")  // missing name tolerated
        #expect(try JSONDecoder().decode(Macros.self, from: Data("{}".utf8)).macros.isEmpty)
    }

    @Test func defaultHasAStarterMacro() {
        #expect(Macros.default.macros.contains { $0.name == "Flatten & Filter" })
    }

    @Test func roundTrips() throws {
        let original = Macros(macros: [Macro(name: "A", commands: ["one", "two"])])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Macros.self, from: data) == original)
    }
}
