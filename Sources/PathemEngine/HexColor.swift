import Foundation

/// The one parser/formatter for the "#RRGGBB" / "#RRGGBBAA" color strings the engine owns
/// (Preferences.accentColorHex, ThemePreset, ColorRule.colorHex, FolderBackground, ...). Pure
/// Foundation, so the AppKit layer builds NSColor from these components instead of each site
/// re-implementing the hex parse.
public enum HexColor {
    /// Parse "#RRGGBB" or "#RRGGBBAA" (the "#" optional) into 0...1 sRGB components; nil if
    /// malformed. Alpha is 1 when omitted.
    public static func parse(_ raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        guard !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        return (
            r: Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255,
            g: Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255,
            b: Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255,
            a: hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }

    /// Format 0...1 sRGB components as "#RRGGBB".
    public static func format(r: Double, g: Double, b: Double) -> String {
        String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    private static func clamp(_ v: Double) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
}
