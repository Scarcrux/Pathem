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

    public init(name: String, appearance: Preferences.Appearance, accentHex: String, backgroundHex: String = "") {
        self.name = name
        self.appearance = appearance
        self.accentHex = accentHex
        self.backgroundHex = backgroundHex
    }

    /// Built-in skins. "System" restores the stock look (system accent, no tint, system appearance).
    public static let presets: [ThemePreset] = [
        .init(name: "System", appearance: .system, accentHex: "", backgroundHex: ""),
        .init(name: "Graphite", appearance: .system, accentHex: "#8A8A8F", backgroundHex: ""),
        .init(name: "Midnight", appearance: .dark, accentHex: "#5E9EFF", backgroundHex: "#0B0F17"),
        .init(name: "Solarized", appearance: .dark, accentHex: "#268BD2", backgroundHex: "#002B36"),
        .init(name: "Nord", appearance: .dark, accentHex: "#88C0D0", backgroundHex: "#2E3440"),
        .init(name: "Dracula", appearance: .dark, accentHex: "#BD93F9", backgroundHex: "#282A36"),
        .init(name: "Rose", appearance: .light, accentHex: "#D6336C", backgroundHex: "#FFF0F3"),
        .init(name: "Forest", appearance: .light, accentHex: "#2F9E44", backgroundHex: "#F0FDF4"),
        .init(name: "Sand", appearance: .light, accentHex: "#B7791F", backgroundHex: "#FBF7EF"),
        .init(name: "High Contrast", appearance: .dark, accentHex: "#FFD400", backgroundHex: "#000000"),
    ]

    /// The preset whose three values match `prefs`, or nil when the user has a custom combination.
    public static func matching(accentHex: String, backgroundHex: String, appearance: Preferences.Appearance) -> ThemePreset? {
        presets.first {
            $0.accentHex.caseInsensitiveCompare(accentHex) == .orderedSame
                && $0.backgroundHex.caseInsensitiveCompare(backgroundHex) == .orderedSame
                && $0.appearance == appearance
        }
    }
}
