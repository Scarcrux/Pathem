import Foundation

/// Ordering for the customizable file right-click menu. The menu is a list of entry
/// tokens (command ids, plus "@openWith" / "@tags" for the two submenus); separators
/// are auto-inserted between groups by the app, so they aren't part of this order.
public enum ContextMenuLayout {
    /// The effective entry order: the user's saved order, filtered to entries that still
    /// exist in `default` (so a command removed in a later version drops out), followed by
    /// any `default` entries the saved order is missing (so a command added in a later
    /// version still appears), in their default order. An empty saved order = the default.
    public static func ordered(default def: [String], user: [String]) -> [String] {
        guard !user.isEmpty else { return def }
        let valid = Set(def)
        var result = user.filter { valid.contains($0) }
        let present = Set(result)
        for token in def where !present.contains(token) { result.append(token) }
        return result
    }
}
