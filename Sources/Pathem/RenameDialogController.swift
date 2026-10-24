import AppKit

/// Owns the complete production dialog, including asynchronous accessory remeasurement.
@MainActor
final class RenameDialogController {
    let alert = NSAlert()
    let field: NSTextField
    let suggestion: FilenameSuggestionController?

    init(
        name: String, url: URL, dataless: Bool, offerSuggestions: Bool,
        generateAutomatically: Bool = true
    ) {
        field = BrowserViewController.nameField(prefilled: name)
        suggestion =
            offerSuggestions
            ? FilenameSuggestionController(
                field: field, url: url, dataless: dataless,
                generateAutomatically: generateAutomatically) : nil
        alert.messageText = L("bvc.renameTitleShort", "Rename")
        alert.informativeText = L("bvc.renamePrompt", "Enter a new name for this item.")
        alert.addButton(withTitle: L("bvc.renameButton", "Rename"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        if let suggestion {
            let width = max(380, field.frame.width)
            suggestion.setLayoutWidth(width)
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            let stack = NSStackView(views: [field, suggestion.view])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            let accessory = MeasuredAccessoryView(content: stack, width: width)
            accessory.onSizeChanged = { [weak alert] in alert?.layout() }
            suggestion.onLayoutChanged = { [weak accessory] in accessory?.resizeToFit() }
            alert.accessoryView = accessory
        } else {
            alert.accessoryView = field
        }
        alert.window.initialFirstResponder = field
    }

    func cancel() { suggestion?.cancel() }
}
