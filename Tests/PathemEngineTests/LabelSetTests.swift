import Foundation
import Testing

@testable import PathemEngine

@Suite struct LabelSetTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func defaultsAreNamedAndColored() {
        let set = LabelSet.default
        #expect(set.labels.contains { $0.name == "Important" && $0.color == .red })
        #expect(set.labels.allSatisfy { !$0.name.isEmpty })
    }

    @Test func aLabelWritesAnInteroperableTag() {
        let label = FileLabel(name: "Work", color: .blue)
        #expect(label.tag == FileTag(name: "Work", color: .blue))
    }

    @Test func roundTripsThroughJSON() throws {
        let original = LabelSet(labels: [FileLabel(name: "Hot", color: .orange)])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LabelSet.self, from: data) == original)
    }

    @Test func tolerantOfUnknownColorAndMissingKeys() throws {
        // An out-of-range color falls back to .none; a missing labels key is empty.
        let set = try decode(LabelSet.self, #"{"labels":[{"name":"X","color":99}]}"#)
        #expect(set.labels.first?.color == FileTag.Color.none)
        #expect(try decode(LabelSet.self, "{}").labels.isEmpty)
    }
}
