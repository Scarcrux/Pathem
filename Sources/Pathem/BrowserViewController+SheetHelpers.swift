import AppKit
import PathemEngine

// Generic NSAlert/sheet presentation helpers used throughout BrowserViewController: an
// async sheet-await wrapper, a name-prompt dialog, and info/failure/checksum-result
// alerts. Split out of BrowserViewController.
extension BrowserViewController {
    // MARK: - Sheet helpers

    /// A modal single-line name prompt; nil if cancelled or empty.
    /// Present `alert` as a sheet attached to the window -- so it appears on the window
    /// (dropping from its title bar), not centered on the whole screen -- and await its
    /// response. Falls back to a screen-centered app-modal alert when there is no window yet.
    func presentSheet(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    func promptForName(title: String, default value: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = Self.nameField(prefilled: value)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard await presentSheet(alert) == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A single-line text field for a name/rename prompt, sized to comfortably show `value`
    /// within a sensible range, so a long filename isn't clipped the way a fixed-width field
    /// clips it. Pre-fills the field with the current name.
    static func nameField(prefilled value: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        // Grow to fit the text (capped), so long names are visible without a giant sheet; the
        // field still scrolls horizontally while editing past the cap.
        let fitting = field.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 24)).width ?? 300
        field.frame = NSRect(x: 0, y: 0, width: min(520, max(300, ceil(fitting) + 16)), height: 24)
        return field
    }

    func presentInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
    }

    func presentFailures(_ failures: [FileOperations.Failure], title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("bvc.failuresForItems", "%@ for %d item(s)"), title, failures.count)
        alert.informativeText =
            failures.prefix(8).map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func presentChecksumResult(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }
}
