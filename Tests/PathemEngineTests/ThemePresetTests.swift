import Foundation
import Testing

@testable import PathemEngine

@Suite struct ThemePresetTests {
    /// Preferences store the theme by name, so names that shipped must keep working.
    @Test func shippedNamesStillExist() {
        let names = Set(ThemePreset.presets.map(\.name))
        for name in [
            "System", "Graphite", "Midnight", "Solarized", "Nord", "Dracula", "Rose", "Forest",
            "Sand", "High Contrast",
        ] {
            #expect(names.contains(name), "\(name) was removed")
        }
        #expect(names.count == ThemePreset.presets.count, "duplicate theme names")
    }

    /// The menus label each theme light or dark from its appearance; the background must agree,
    /// or a "light" theme would paint a dark window.
    @Test func appearanceMatchesTheBackground() throws {
        for preset in ThemePreset.presets where !preset.backgroundHex.isEmpty {
            let c = try #require(HexColor.parse(preset.backgroundHex), "\(preset.name) background")
            let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            switch preset.appearance {
            case .light: #expect(luminance > 0.6, "\(preset.name) is labelled light")
            case .dark: #expect(luminance < 0.3, "\(preset.name) is labelled dark")
            case .system: Issue.record("\(preset.name) follows the system but sets a background")
            }
            #expect(HexColor.parse(preset.accentHex) != nil, "\(preset.name) accent")
        }
    }

    @Test func groupsListEveryThemeOnceInOrder() {
        let groups = ThemePreset.groups
        #expect(groups.map(\.appearance) == [.system, .light, .dark])
        let indexes = groups.flatMap { $0.members.map(\.index) }
        #expect(indexes.sorted() == Array(ThemePreset.presets.indices))
        for group in groups {
            #expect(group.members.allSatisfy { $0.preset.appearance == group.appearance })
        }
        #expect(groups.first { $0.appearance == .light }!.members.count >= 6)
        #expect(groups.first { $0.appearance == .dark }!.members.count >= 6)
    }
}
