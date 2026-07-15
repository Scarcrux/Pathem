import Testing

@testable import PathemEngine

@Suite struct FinderTagsTests {
    private let colors: Set<String> = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    @Test func keepsOnlyCustomNames() {
        // FavoriteTagNames as Finder stores it: a leading empty placeholder, the seven colors, then
        // whatever the user named. Only the custom ones should survive.
        let raw = ["", "Red", "Green", "Work", "Invoices", "To Read"]
        #expect(FinderTags.customNames(from: raw, colorNames: colors) == ["Work", "Invoices", "To Read"])
    }

    @Test func trimsAndDedupsCaseInsensitively() {
        let raw = [" Work ", "work", "WORK", "  ", "Home"]
        #expect(FinderTags.customNames(from: raw, colorNames: colors) == ["Work", "Home"])
    }

    @Test func emptyWhenOnlyColors() {
        #expect(FinderTags.customNames(from: ["", "Red", "Blue"], colorNames: colors).isEmpty)
    }
}
