import Foundation
import Testing

@testable import PathemEngine

@Suite struct LayoutTests {
    private func layout(_ name: String, left: String = "/a", right: String = "/b") -> Layout {
        Layout(name: name, leftPath: left, rightPath: right, dividerFraction: 0.5)
    }

    @Test func saveReplacesByName() {
        var layouts = Layouts()
        layouts.save(layout("work", left: "/a", right: "/b"))
        layouts.save(layout("work", left: "/x", right: "/y"))
        #expect(layouts.layouts.count == 1)
        #expect(layouts.named("work")?.leftPath == "/x")
    }

    @Test func namedAndNamesInOrder() {
        var layouts = Layouts()
        layouts.save(layout("a"))
        layouts.save(layout("b"))
        #expect(layouts.names == ["a", "b"])
        #expect(layouts.named("missing") == nil)
    }

    @Test func codableRoundTrip() throws {
        var layouts = Layouts()
        layouts.save(layout("work"))
        let data = try JSONEncoder().encode(layouts)
        let restored = try JSONDecoder().decode(Layouts.self, from: data)
        #expect(restored.named("work") == layouts.named("work"))
    }
}
