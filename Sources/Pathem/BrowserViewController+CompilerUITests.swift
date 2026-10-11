#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// A compiler warning can encode a user-visible semantic bug. Exercise the
    /// installed menu and registry, including a differing Kind control.
    func runCompilerUIAutomation() -> Never {
        func item(_ id: String, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for candidate in menu.items {
                if candidate.representedObject as? String == id { return candidate }
                if let found = item(id, in: candidate.submenu) { return found }
            }
            return nil
        }
        var checks: [(String, Bool)] = []
        if let none = item("view.arrangeNone", in: NSApp.mainMenu),
            let kind = item("view.arrangeKind", in: NSApp.mainMenu), let pane = activePane
        {
            let original = pane.groupKey
            pane.setGroupKey(ViewFormat.GroupKey.none)
            _ = validateMenuItem(none)
            checks.append(("arrange-none-checked", none.state == .on))
            checks.append(
                (
                    "arrange-kind-command-delivered",
                    commands.perform("view.arrangeKind") && pane.groupKey == .kind
                ))
            _ = validateMenuItem(none)
            _ = validateMenuItem(kind)
            checks.append(
                ("arrange-kind-differing-control", kind.state == .on && none.state == .off))
            _ = commands.perform("view.arrangeNone")
            _ = validateMenuItem(none)
            checks.append(
                (
                    "arrange-none-command-restores-checkmark",
                    pane.groupKey == ViewFormat.GroupKey.none && none.state == .on
                ))
            pane.setGroupKey(original)
        } else {
            checks.append(("installed-arrange-menu-delivered", false))
        }
        for (name, ok) in checks { print("COMPILERUI: \(ok ? "PASS" : "FAIL") \(name)") }
        let passed = checks.filter(\.1).count
        print("RESULT: \(passed == checks.count ? "PASS" : "FAIL") (\(passed)/\(checks.count))")
        exit(passed == checks.count ? 0 : 1)
    }
}
#endif
