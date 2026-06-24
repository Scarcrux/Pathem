import AppKit

/// Detects installed developer editors so Pathem can offer "Open in <editor>" for the
/// current/selected folder, the fastest path from browsing to working. Pure lookup
/// by bundle identifier; no launching here.
enum ExternalEditors {
    /// Known editors in rough priority order, each with the bundle IDs it has shipped
    /// under (so a stable/CE/older variant is still found).
    private static let known: [(name: String, ids: [String])] = [
        ("Visual Studio Code", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        ("Cursor", ["com.todesktop.230313mzl4w4u92"]),
        ("Zed", ["dev.zed.Zed"]),
        ("Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"]),
        ("Nova", ["com.panic.Nova"]),
        ("BBEdit", ["com.barebones.bbedit"]),
        ("IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        ("PyCharm", ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        ("WebStorm", ["com.jetbrains.WebStorm"]),
        ("GoLand", ["com.jetbrains.goland"]),
        ("Android Studio", ["com.google.android.studio"]),
        ("Xcode", ["com.apple.dt.Xcode"]),
        ("TextMate", ["com.macromates.TextMate"]),
    ]

    struct Editor: Equatable {
        let name: String
        let url: URL
    }

    /// The installed editors, in priority order.
    static func installed() -> [Editor] {
        let workspace = NSWorkspace.shared
        return known.compactMap { entry in
            for id in entry.ids {
                if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                    return Editor(name: entry.name, url: url)
                }
            }
            return nil
        }
    }
}
