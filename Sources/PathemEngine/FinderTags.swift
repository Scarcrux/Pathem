import Foundation

/// Reads the user's Finder tag list, so Pathem's sidebar Tags section can show the same custom,
/// named tags Finder does -- not only the seven built-in colors. Finder keeps the list in its own
/// preference (`com.apple.finder` -> `FavoriteTagNames`), which any non-sandboxed app can read.
/// Pure Foundation, and the filtering is split from the preference read so it is unit-testable.
public enum FinderTags {
    /// The custom (non-color) tag names in a raw FavoriteTagNames array: trimmed, de-duplicated,
    /// with the empty placeholder and the seven standard color names removed.
    public static func customNames(from raw: [String], colorNames: Set<String>) -> [String] {
        var seen = Set<String>()
        return
            raw
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !colorNames.contains($0) && seen.insert($0.lowercased()).inserted }
    }

    /// The user's custom Finder tag names (beyond the seven colors), from Finder's own preference.
    public static func customNames(colorNames: Set<String>) -> [String] {
        let raw =
            UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String] ?? []
        return customNames(from: raw, colorNames: colorNames)
    }
}
