import AppKit
@preconcurrency import SwiftTerm

/// Terminal appearance and shell, persisted as config-as-data (terminal.json):
/// font, foreground/background/cursor colors, the 16-color ANSI palette, and
/// which shell to launch. Colors are "#RRGGBB" strings; empty means "use the
/// system default" so the System theme follows light/dark mode. Empty `ansi`
/// leaves SwiftTerm's built-in palette. Empty `shellPath` uses $SHELL or zsh.
public struct TerminalTheme: Codable, Sendable, Equatable {
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var foreground: String
    public var background: String
    public var cursor: String
    public var ansi: [String]
    public var shellPath: String

    public init(
        name: String, fontName: String = "Menlo", fontSize: Double = 12,
        foreground: String = "", background: String = "", cursor: String = "",
        ansi: [String] = [], shellPath: String = ""
    ) {
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
        self.shellPath = shellPath
    }

    // Tolerant: a terminal.json from an older build (missing newer keys) loads with
    // defaults rather than failing and resetting the saved theme.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Menlo"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12
        foreground = try c.decodeIfPresent(String.self, forKey: .foreground) ?? ""
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        ansi = try c.decodeIfPresent([String].self, forKey: .ansi) ?? []
        shellPath = try c.decodeIfPresent(String.self, forKey: .shellPath) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case name, fontName, fontSize, foreground, background, cursor, ansi, shellPath
    }

    // MARK: Color helpers

    private static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    static func nsColor(_ hex: String) -> NSColor? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        return NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// SwiftTerm.Color uses 16-bit components, so scale each byte by 257.
    static func termColor(_ hex: String) -> SwiftTerm.Color? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    // MARK: Presets

    public static let system = TerminalTheme(name: "System")

    public static let dracula = TerminalTheme(
        name: "Dracula", foreground: "#F8F8F2", background: "#282A36", cursor: "#F8F8F2",
        ansi: [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        ])

    public static let nord = TerminalTheme(
        name: "Nord", foreground: "#D8DEE9", background: "#2E3440", cursor: "#D8DEE9",
        ansi: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        ])

    private static let solarizedANSI = [
        "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
        "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
    ]

    public static let solarizedDark = TerminalTheme(
        name: "Solarized Dark", foreground: "#839496", background: "#002B36", cursor: "#93A1A1",
        ansi: solarizedANSI)

    public static let solarizedLight = TerminalTheme(
        name: "Solarized Light", foreground: "#657B83", background: "#FDF6E3", cursor: "#586E75",
        ansi: solarizedANSI)

    public static let gruvboxDark = TerminalTheme(
        name: "Gruvbox Dark", foreground: "#EBDBB2", background: "#282828", cursor: "#EBDBB2",
        ansi: [
            "#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
        ])

    public static let monokai = TerminalTheme(
        name: "Monokai", foreground: "#F8F8F2", background: "#272822", cursor: "#F8F8F0",
        ansi: [
            "#272822", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
            "#75715E", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5",
        ])

    public static let oneDark = TerminalTheme(
        name: "One Dark", foreground: "#ABB2BF", background: "#282C34", cursor: "#528BFF",
        ansi: [
            "#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
            "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF",
        ])

    public static let tokyoNight = TerminalTheme(
        name: "Tokyo Night", foreground: "#C0CAF5", background: "#1A1B26", cursor: "#C0CAF5",
        ansi: [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
        ])

    public static let catppuccinMocha = TerminalTheme(
        name: "Catppuccin Mocha", foreground: "#CDD6F4", background: "#1E1E2E", cursor: "#F5E0DC",
        ansi: [
            "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
            "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
        ])

    public static let githubLight = TerminalTheme(
        name: "GitHub Light", foreground: "#24292E", background: "#FFFFFF", cursor: "#24292E",
        ansi: [
            "#24292E", "#D73A49", "#28A745", "#DBAB09", "#0366D6", "#5A32A3", "#0598BC", "#6A737D",
            "#959DA5", "#CB2431", "#22863A", "#B08800", "#005CC5", "#5A32A3", "#3192AA", "#D1D5DA",
        ])

    /// The "System" theme as it looks inside an app whose window has `background` (a "#RRGGBB"
    /// tint): that background, a readable foreground, `accent` as the cursor, and a light or
    /// dark ANSI palette to match. Still named "System", so it reads as the default in menus.
    /// An empty or invalid background gives plain `.system` (follow the macOS appearance).
    public static func system(followingBackground background: String, accent: String)
        -> TerminalTheme
    {
        guard let (r, g, b) = rgb(background) else { return .system }
        let luminance = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
        let dark = luminance < 0.5
        let base = dark ? oneDark : githubLight
        return TerminalTheme(
            name: system.name, foreground: dark ? "#D8DCE3" : "#2B2B2B", background: background,
            cursor: rgb(accent) == nil ? base.cursor : accent, ansi: base.ansi)
    }

    public static let presets: [TerminalTheme] = [
        system, dracula, nord, solarizedDark, solarizedLight,
        gruvboxDark, monokai, oneDark, tokyoNight, catppuccinMocha, githubLight,
    ]
}
