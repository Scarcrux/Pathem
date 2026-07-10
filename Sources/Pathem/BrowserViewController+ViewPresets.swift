import AppKit
import PathemEngine

// Saved view presets: view mode/sort/grouping snapshots users can reapply to
// any folder. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    private static var viewPresetsURL: URL? { appSupportDirectory()?.appendingPathComponent("view-presets.json") }

    func loadViewPresets() {
        viewPresets = loadConfig(ViewPresets.self, from: Self.viewPresetsURL) ?? .default
        registerViewPresetCommands()
    }
    /// Register each saved view as a command (so it appears in the palette and is bindable).
    private func registerViewPresetCommands() {
        for command in commands.all where command.id.hasPrefix("viewpreset.") { commands.unregister(command.id) }
        for preset in viewPresets.presets where !preset.name.isEmpty {
            let format = preset.format
            let name = preset.name
            commands.register(
                .init(
                    id: "viewpreset.\(name)", title: String(format: L("bvc.viewPresetCmd", "View: %@"), name),
                    isEnabled: { [weak self] in self?.activePane != nil },
                    run: { [weak self] in self?.applyViewPreset(format) }))
        }
    }
    private func applyViewPreset(_ format: ViewFormat) {
        guard let pane = activePane else { NSSound.beep(); return }
        pane.applyFormat(format)
        pane.setGroupKey(format.groupKey)  // applyFormat doesn't touch grouping
    }
    /// Prompt for a name and save the active pane's current view as a reusable preset.
    @objc func saveViewPreset() {
        guard let pane = activePane, let window = view.window else { NSSound.beep(); return }
        _ = window
        let format = pane.format
        let alert = NSAlert()
        alert.messageText = L("viewpreset.saveTitle", "Save Current View As")
        alert.informativeText = L("viewpreset.saveHint", "Captures the view mode, sort, grouping, and hidden / folders-first, to apply to any folder.")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L("viewpreset.name", "preset name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.viewPresets.save(.init(name: name, format: format))
            self.saveConfig(self.viewPresets, to: Self.viewPresetsURL)
            self.registerViewPresetCommands()
        }
    }

    @objc func applyViewPresetMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
            let preset = viewPresets.presets.first(where: { $0.name == name })
        else { return }
        applyViewPreset(preset.format)
    }
}
