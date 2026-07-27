import AppKit
import PathemEngine

/// Repopulates the toolbar "…" overflow menu each time it opens, so checkmarks (current theme,
/// appearance) are always fresh. Kept as a small delegate so BrowserViewController's own menu
/// handling stays untouched.
@MainActor
final class OverflowMenuDelegate: NSObject, NSMenuDelegate {
    private weak var browser: BrowserViewController?
    init(browser: BrowserViewController) { self.browser = browser }
    func menuNeedsUpdate(_ menu: NSMenu) { browser?.populateOverflowMenu(menu) }
}

// The "…" toolbar button's menu: a Theme picker plus a few genuinely-useful quick actions and a
// jump to Settings. Everything here also lives in the menu bar / palette; this is the fast, always
// visible hub the toolbar was missing.
@MainActor
extension BrowserViewController {
    /// Build the overflow menu fresh (called by the delegate on open).
    func populateOverflowMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()

        menu.addItem(themeSubmenuItem())
        menu.addItem(.separator())
        menu.addItem(overflowCommandItem("view.toggleHidden"))
        menu.addItem(overflowCommandItem("view.applyStyle"))
        menu.addItem(overflowCommandItem("view.saveStyle"))
        menu.addItem(overflowCommandItem("view.customizeToolbar"))
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: L("overflow.settings", "Settings…"), action: #selector(openOverflowSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
    }

    /// The Theme submenu: appearance (System/Light/Dark), the built-in skins, and a jump to the
    /// full Appearance settings. The current appearance and skin carry a checkmark.
    private func themeSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("overflow.theme", "Theme"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false

        let appearances: [(String, Preferences.Appearance)] = [
            (L("prefs.appearanceSystem", "System"), .system),
            (L("prefs.appearanceLight", "Light"), .light),
            (L("prefs.appearanceDark", "Dark"), .dark),
        ]
        for (index, entry) in appearances.enumerated() {
            let mi = NSMenuItem(title: entry.0, action: #selector(setOverflowAppearance(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = index
            mi.state = prefs.appearance == entry.1 ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())

        let current = ThemePreset.matching(
            accentHex: prefs.accentColorHex, backgroundHex: prefs.windowTintHex, appearance: prefs.appearance)
        for (index, preset) in ThemePreset.presets.enumerated() {
            let mi = NSMenuItem(title: preset.name, action: #selector(applyOverflowThemePreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = index
            mi.state = preset == current ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let more = NSMenuItem(
            title: L("overflow.themeSettings", "Theme Settings…"), action: #selector(openOverflowSettings), keyEquivalent: "")
        more.target = self
        sub.addItem(more)

        item.submenu = sub
        return item
    }

    /// A menu item that runs a registered command by id, reflecting its current enabled state.
    private func overflowCommandItem(_ id: String) -> NSMenuItem {
        let command = commands.command(id)
        let mi = NSMenuItem(
            title: command?.title ?? id, action: #selector(runOverflowCommand(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = id
        mi.isEnabled = command?.isEnabled() ?? true
        return mi
    }

    @objc private func runOverflowCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { NSSound.beep(); return }
        if !commands.perform(id) { NSSound.beep() }
    }

    @objc private func setOverflowAppearance(_ sender: NSMenuItem) {
        let order: [Preferences.Appearance] = [.system, .light, .dark]
        guard sender.tag < order.count, prefs.appearance != order[sender.tag] else { return }
        prefs.appearance = order[sender.tag]
        persistAndApplyTheme()
    }

    @objc private func applyOverflowThemePreset(_ sender: NSMenuItem) {
        guard sender.tag < ThemePreset.presets.count else { return }
        let preset = ThemePreset.presets[sender.tag]
        prefs.appearance = preset.appearance
        prefs.accentColorHex = preset.accentHex
        prefs.windowTintHex = preset.backgroundHex
        persistAndApplyTheme()
    }

    /// Persist prefs and re-apply, the same path Settings uses, so a theme change from the toolbar is
    /// identical to changing it in Settings ▸ Appearance.
    private func persistAndApplyTheme() {
        saveConfig(prefs, to: Self.preferencesURL)
        applyPreferences()
    }

    @objc private func openOverflowSettings() { showPreferences() }
}
