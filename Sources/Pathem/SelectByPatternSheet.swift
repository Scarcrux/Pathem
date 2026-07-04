import AppKit
import PathemEngine

/// How a pattern match combines with the current selection.
enum SelectionMode: Sendable { case replace, add, subtract }

/// The "Select by Pattern…" sheet: a pattern plus match/kind/mode options. Calls back with
/// the built query and combine-mode when the user applies it. A pure UI front-end over
/// `SelectionQuery`; the matching lives in the engine.
@MainActor
enum SelectByPatternSheet {
    static func present(
        over window: NSWindow, completion: @escaping (SelectionQuery, SelectionMode) -> Void
    ) {
        let pattern = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        pattern.placeholderString = "*.log"

        let match = NSPopUpButton(frame: .zero, pullsDown: false)
        match.addItems(withTitles: [
            L("select.glob", "Wildcard (glob)"), L("select.regex", "Regular expression"),
            L("select.substring", "Contains text"),
        ])
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: [
            L("select.any", "Files and folders"), L("select.files", "Files only"),
            L("select.folders", "Folders only"),
        ])
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: [
            L("select.replace", "Replace selection"), L("select.add", "Add to selection"),
            L("select.remove", "Remove from selection"),
        ])
        let caseBox = NSButton(
            checkboxWithTitle: L("select.caseSensitive", "Case sensitive"), target: nil, action: nil)

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let name = NSTextField(labelWithString: label)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let stack = NSStackView(views: [name, control])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let stack = NSStackView(views: [
            row(L("select.patternLabel", "Pattern"), pattern),
            row(L("select.matchLabel", "Match"), match),
            row(L("select.kindLabel", "Kind"), kind),
            row(L("select.modeLabel", "Then"), mode),
            caseBox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 156)

        let alert = NSAlert()
        alert.messageText = L("select.title", "Select by Pattern")
        alert.informativeText = L(
            "select.help",
            "Select the items whose name matches. Wildcards: * (any run), ? (one character), [0-9] (a range).")
        alert.accessoryView = stack
        alert.addButton(withTitle: L("select.apply", "Select"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.window.initialFirstResponder = pattern
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let matches: [SelectionQuery.Match] = [.glob, .regex, .substring]
            let kinds: [SelectionQuery.Kind] = [.any, .files, .folders]
            let modes: [SelectionMode] = [.replace, .add, .subtract]
            let query = SelectionQuery(
                pattern: pattern.stringValue,
                match: matches[max(0, match.indexOfSelectedItem)],
                kind: kinds[max(0, kind.indexOfSelectedItem)],
                caseSensitive: caseBox.state == .on)
            completion(query, modes[max(0, mode.indexOfSelectedItem)])
        }
    }
}
