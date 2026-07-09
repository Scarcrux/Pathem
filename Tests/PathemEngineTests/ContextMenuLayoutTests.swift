import Foundation
import Testing

@testable import PathemEngine

@Suite struct ContextMenuLayoutTests {
    let def = ["files.open", "@openWith", "files.getInfo", "files.rename", "files.copy"]

    @Test func emptyUserOrderIsDefault() {
        #expect(ContextMenuLayout.ordered(default: def, user: []) == def)
    }

    @Test func userOrderIsHonored() {
        let user = ["files.copy", "files.open", "@openWith", "files.getInfo", "files.rename"]
        #expect(ContextMenuLayout.ordered(default: def, user: user) == user)
    }

    @Test func newDefaultCommandsAppendInDefaultOrder() {
        // The saved order predates "files.getInfo" and "files.copy"; both reappear at the end.
        let user = ["files.rename", "files.open", "@openWith"]
        #expect(
            ContextMenuLayout.ordered(default: def, user: user)
                == ["files.rename", "files.open", "@openWith", "files.getInfo", "files.copy"])
    }

    @Test func removedCommandsAreDropped() {
        // "files.legacy" is no longer a default entry, so it's filtered out.
        let user = ["files.legacy", "files.open", "@openWith", "files.getInfo", "files.rename", "files.copy"]
        #expect(!ContextMenuLayout.ordered(default: def, user: user).contains("files.legacy"))
        #expect(ContextMenuLayout.ordered(default: def, user: user).first == "files.open")
    }
}
