import Testing

@testable import PathomEngine

@Suite struct CommandResolverTests {
    private let commands: [(id: String, title: String)] = [
        ("files.copyToOtherPane", "Copy to Other Pane"),
        ("files.moveToOtherPane", "Move to Other Pane"),
        ("files.paste", "Paste"),
        ("files.open", "Open"),
        ("view.toggleHidden", "Show Hidden Files"),
        ("view.applyToSubfolders", "Apply View to Subfolders"),
        ("nav.up", "Enclosing Folder"),
        ("nav.back", "Back"),
        ("palette.show", "Command Palette…"),
        ("layout.save", "Save Layout…"),
    ]

    @Test func resolvesDirectPhrases() {
        #expect(CommandResolver.resolve("show hidden files", commands: commands) == "view.toggleHidden")
        #expect(CommandResolver.resolve("paste", commands: commands) == "files.paste")
        #expect(CommandResolver.resolve("save layout", commands: commands) == "layout.save")
    }

    @Test func disambiguatesCopyVsMove() {
        #expect(CommandResolver.resolve("copy to the other pane", commands: commands) == "files.copyToOtherPane")
        #expect(CommandResolver.resolve("move these to the other pane", commands: commands) == "files.moveToOtherPane")
    }

    @Test func resolvesViaSynonyms() {
        #expect(CommandResolver.resolve("go up", commands: commands) == "nav.up")  // up -> enclosing
        #expect(CommandResolver.resolve("open the command palette", commands: commands) == "palette.show")
        #expect(CommandResolver.resolve("apply recursively", commands: commands) == "view.applyToSubfolders")
    }

    @Test func returnsNilForGibberishOrEmpty() {
        #expect(CommandResolver.resolve("asdfqwer zxcvbn", commands: commands) == nil)
        #expect(CommandResolver.resolve("", commands: commands) == nil)
        #expect(CommandResolver.resolve("the a to of", commands: commands) == nil)  // only stopwords
    }
}
