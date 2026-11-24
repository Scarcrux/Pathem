import Foundation

/// A named skin: an appearance (light/dark/system) plus an accent color and an optional window
/// background tint, as "#RRGGBB" strings so the model stays Foundation-only (the app maps them to
/// NSColor). Applying a preset just writes its three values into `Preferences`, which are the
/// source of truth; a preset is a convenient bundle. An empty accent means "use the system accent".
public struct ThemePreset: Codable, Sendable, Equatable {
    public var name: String
    public var appearance: Preferences.Appearance
    public var accentHex: String
    public var backgroundHex: String  // "" = system background

    public init(
        name: String, appearance: Preferences.Appearance, accentHex: String,
        backgroundHex: String = ""
    ) {
        self.name = name
        self.appearance = appearance
        self.accentHex = accentHex
        self.backgroundHex = backgroundHex
    }

    public static let system = ThemePreset(name: "System", appearance: .system, accentHex: "")
    public static let harbor = ThemePreset(
        name: "Harbor", appearance: .dark, accentHex: "#82D4DE", backgroundHex: "#182630")

    public init(preferences: Preferences) {
        self.init(
            name: preferences.themeName, appearance: preferences.appearance,
            accentHex: preferences.accentColorHex, backgroundHex: preferences.windowTintHex)
    }

    public func apply(to preferences: inout Preferences) {
        preferences.themeName = name
        preferences.appearance = appearance
        preferences.accentColorHex = accentHex
        preferences.windowTintHex = backgroundHex
    }

    /// Built-in skins, grouped: those that follow the system appearance, then light, then dark.
    /// "System" restores the stock look (system accent, no tint, system appearance). Names are
    /// stored in preferences, so existing names never change. The added palettes follow
    /// well-known open-source color schemes (their published background and accent colors).
    public static let presets: [ThemePreset] = [
        system,
        .init(name: "Graphite", appearance: .system, accentHex: "#8A8A8F", backgroundHex: ""),
        // Light
        .init(name: "Paper", appearance: .light, accentHex: "#0969DA", backgroundHex: "#FAFAF8"),
        .init(name: "Rose", appearance: .light, accentHex: "#D6336C", backgroundHex: "#FFF0F3"),
        .init(name: "Forest", appearance: .light, accentHex: "#2F9E44", backgroundHex: "#F0FDF4"),
        .init(name: "Sand", appearance: .light, accentHex: "#B7791F", backgroundHex: "#FBF7EF"),
        .init(name: "Ocean", appearance: .light, accentHex: "#0077B6", backgroundHex: "#F0F7FB"),
        .init(
            name: "Solarized Light", appearance: .light, accentHex: "#268BD2",
            backgroundHex: "#FDF6E3"),
        .init(
            name: "Catppuccin Latte", appearance: .light, accentHex: "#8839EF",
            backgroundHex: "#EFF1F5"),
        .init(
            name: "Gruvbox Light", appearance: .light, accentHex: "#AF3A03",
            backgroundHex: "#FBF1C7"),
        .init(
            name: "Rosé Pine Dawn", appearance: .light, accentHex: "#907AA9",
            backgroundHex: "#FAF4ED"),
        // Dark
        .init(name: "Midnight", appearance: .dark, accentHex: "#5E9EFF", backgroundHex: "#0B0F17"),
        .init(name: "Solarized", appearance: .dark, accentHex: "#268BD2", backgroundHex: "#002B36"),
        .init(name: "Nord", appearance: .dark, accentHex: "#88C0D0", backgroundHex: "#2E3440"),
        .init(name: "Dracula", appearance: .dark, accentHex: "#BD93F9", backgroundHex: "#282A36"),
        .init(
            name: "Catppuccin Mocha", appearance: .dark, accentHex: "#CBA6F7",
            backgroundHex: "#1E1E2E"),
        .init(
            name: "Gruvbox Dark", appearance: .dark, accentHex: "#FE8019", backgroundHex: "#282828"),
        .init(name: "One Dark", appearance: .dark, accentHex: "#61AFEF", backgroundHex: "#282C34"),
        .init(
            name: "Tokyo Night", appearance: .dark, accentHex: "#7AA2F7", backgroundHex: "#1A1B26"),
        .init(name: "Rosé Pine", appearance: .dark, accentHex: "#C4A7E7", backgroundHex: "#191724"),
        .init(
            name: "Everforest", appearance: .dark, accentHex: "#A7C080", backgroundHex: "#2D353B"),
        .init(
            name: "High Contrast", appearance: .dark, accentHex: "#FFD400", backgroundHex: "#000000"
        ),
        harbor,
    ]

    /// The presets in display groups (follows system, light, dark), each with its indexes into
    /// `presets`, so menus can show which themes are light and which are dark.
    public static var groups:
        [(appearance: Preferences.Appearance, members: [(index: Int, preset: ThemePreset)])]
    {
        [Preferences.Appearance.system, .light, .dark].map { appearance in
            (
                appearance,
                presets.enumerated().filter { $0.element.appearance == appearance }
                    .map { (index: $0.offset, preset: $0.element) }
            )
        }
    }

    /// The preset whose three values match `prefs`, or nil when the user has a custom combination.
    public static func matching(
        accentHex: String, backgroundHex: String, appearance: Preferences.Appearance
    ) -> ThemePreset? {
        presets.first {
            $0.accentHex.caseInsensitiveCompare(accentHex) == .orderedSame
                && $0.backgroundHex.caseInsensitiveCompare(backgroundHex) == .orderedSame
                && $0.appearance == appearance
        }
    }
}
