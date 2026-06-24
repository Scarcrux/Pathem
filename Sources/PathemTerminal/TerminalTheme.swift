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
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
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

    public static let presets: [TerminalTheme] = [
        system, dracula, nord, solarizedDark, solarizedLight,
    ]
}
