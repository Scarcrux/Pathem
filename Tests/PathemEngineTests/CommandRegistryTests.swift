import Testing

@testable import PathemEngine

@Suite struct CommandRegistryTests {
    @MainActor @Test func registersAndPerforms() {
        let registry = CommandRegistry()
        var ran = 0
        registry.register(.init(id: "x", title: "X") { ran += 1 })

        #expect(registry.perform("x"))
        #expect(ran == 1)
        #expect(registry.command("x")?.title == "X")
        #expect(registry.all.count == 1)
    }

    @MainActor @Test func respectsIsEnabledAndUnknownIds() {
        let registry = CommandRegistry()
        var ran = 0
        registry.register(.init(id: "x", title: "X", isEnabled: { false }) { ran += 1 })

        #expect(!registry.perform("x"))  // disabled
        #expect(!registry.perform("nope"))  // unknown id
        #expect(ran == 0)
    }

    @MainActor @Test func reRegisterReplacesWithoutDuplicatingOrder() {
        let registry = CommandRegistry()
        registry.register(.init(id: "x", title: "A") {})
        registry.register(.init(id: "x", title: "B") {})

        #expect(registry.all.count == 1)
        #expect(registry.command("x")?.title == "B")
    }
}
