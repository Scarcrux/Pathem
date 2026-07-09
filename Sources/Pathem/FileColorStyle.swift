import AppKit
import PathemEngine

/// Resolves a filename's user color rule (Directory-Opus-style labels) to a text color and
/// font. One entry point shared by every pane view so coloring is consistent.
@MainActor
enum FileColorStyle {
    /// The color and font for `entry` under `rules`, or nil when no rule matches (or the
    /// matching rule sets neither a color nor a bold/italic trait). `baseFont` is the view's
    /// normal filename font; the traits are layered onto it.
    static func style(for entry: FileEntry, rules: ColorRules, baseFont: NSFont)
        -> (color: NSColor?, font: NSFont)?
    {
        guard !rules.rules.isEmpty,
            let rule = rules.match(name: entry.name, isDirectory: entry.isDirectory, size: entry.size)
        else { return nil }
        let color = rule.colorHex.isEmpty ? nil : ThemeManager.color(fromHex: rule.colorHex)
        var font = baseFont
        if rule.bold || rule.italic {
            var traits: NSFontTraitMask = []
            if rule.bold { traits.insert(.boldFontMask) }
            if rule.italic { traits.insert(.italicFontMask) }
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
        }
        guard color != nil || font != baseFont else { return nil }  // rule matched but is a no-op
        return (color, font)
    }
}
