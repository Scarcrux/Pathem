import AppKit
import PathemEngine

// Find-as-you-type wiring: what the pane's bar needs from the app (the command registry for `>`,
// semantic search for `?`) and the command that opens the bar without a keystroke.
@MainActor
extension BrowserViewController {
    func typeAheadHooks(for pane: PaneController) -> TypeAheadHooks {
        var hooks = TypeAheadHooks()
        hooks.commandItems = { [weak self] in
            guard let self else { return [] }
            return self.commands.all.filter { $0.isEnabled() }.map {
                TypeAhead.CommandItem(id: $0.id, title: $0.title, keywords: $0.keywords)
            }
        }
        hooks.runCommand = { [weak self] id in self?.commands.perform(id) }
        hooks.semanticSearch = { [weak self] query in self?.performSearch(query) }
        hooks.semanticRefusal = { [weak self, weak pane] in
            guard let self, let pane else { return nil }
            return self.semanticRefusal(for: pane)
        }
        return hooks
    }

    /// Open the active pane's find-as-you-type field (the "Find as You Type" command).
    func showTypeAhead() {
        activePane?.typeAhead.open()
    }
}

#if DEBUG
extension TypeAheadController {
    /// PATHEM_TYPEAHEAD_SHOT: set the field's text as if typed.
    func debugType(_ text: String) {
        if !isOpen { open() }
        idleSeconds = 3600
        bar.field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// Press Tab in the field (cycles Find and Filter; completes in Go).
    func debugTab() {
        _ = control(
            bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
    }

    var debugSummary: String {
        "mode=\(effectiveMode.rawValue) text=\(text) readout=\(bar.readout.stringValue) "
            + "segment=\(bar.segments.selectedSegment) a11y=\(bar.field.accessibilityLabel() ?? "")"
    }
}

extension BrowserViewController {
    /// Render the bar in each mode over the demo Downloads folder, printing the state each time.
    func runTypeAheadShots(into directory: String, done: @escaping () -> Void) {
        guard let pane = activePane else { return done() }
        let bar = pane.typeAhead
        let root = pane.currentURL.deletingLastPathComponent().path
        let steps: [(String, () -> Void)] = [
            ("find", { bar.debugType("in") }),
            (
                "filter",
                {
                    bar.debugType("")
                    bar.debugTab()
                    bar.debugType("ext:pdf")
                }
            ),
            ("go", { bar.debugType(root + "/Do") }),
            ("command", { bar.debugType(">new fol") }),
            ("search", { bar.debugType("?sunset photos") }),
        ]
        bar.open()
        var delay = 0.8
        for (name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
                print("TYPEAHEAD \(name): \(bar.debugSummary) rows=\(pane.entries.count)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) {
                self.debugRender(to: directory + "/typeahead-\(name).png")
            }
            delay += 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3, execute: done)
    }
}
#endif
