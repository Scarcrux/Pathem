import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {

    // MARK: - User-defined external commands

    private static var externalCommandsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("external-commands.json")
    }
    func loadExternalCommands() {
        externalCommands = loadConfig([ExternalCommand].self, from: Self.externalCommandsURL) ?? []
        registerExternalCommandCommands()
    }
    private func saveExternalCommands() {
        saveConfig(externalCommands, to: Self.externalCommandsURL)
        registerExternalCommandCommands()
    }

    /// Register one command per external command so each shows in the palette and is bindable in
    /// Settings > Shortcuts. Selection-referencing ones require a non-empty local selection.
    private func registerExternalCommandCommands() {
        for command in commands.all where command.id.hasPrefix("external.cmd.") {
            commands.unregister(command.id)
        }
        for command in externalCommands {
            commands.register(
                .init(
                    id: "external.cmd.\(command.id)",
                    title: String(format: L("extcmd.commandTitle", "Command: %@"), command.name),
                    isEnabled: { [weak self] in
                        guard let pane = self?.activePane, !pane.isRemote else { return false }
                        return !command.usesSelection || !pane.selectedEntries.isEmpty
                    },
                    run: { [weak self] in self?.runExternalCommand(command) }))
        }
    }

    private func runExternalCommand(_ command: ExternalCommand) {
        guard let pane = activePane, !pane.isRemote else {
            NSSound.beep()
            return
        }
        if command.usesSelection && pane.selectedEntries.isEmpty {
            NSSound.beep()
            return
        }
        externalOutput.run(command, files: pane.selectedLocalURLs(), directory: pane.currentURL)
    }

    func showExternalCommandsManager() {
        guard let window = view.window else { return }
        externalCommandsController.present(
            over: window, commands: externalCommands,
            onChange: { [weak self] commands in
                self?.externalCommands = commands
                self?.saveExternalCommands()
            },
            onRun: { [weak self] command in self?.runExternalCommand(command) })
    }

    /// Add a "External Commands" submenu to the Tools menu (built in PathemApp before the browser
    /// exists), listing each command plus a Manage entry.
    func installExternalCommandsMenu() {
        menuInstaller.installExternalCommandsMenu(delegate: self)
    }

    func populateExternalCommandsMenu() {
        externalCommandsMenu.removeAllItems()
        for command in externalCommands {
            let item = externalCommandsMenu.addItem(
                withTitle: command.name, action: #selector(runExternalCommandMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = command.id
        }
        if !externalCommands.isEmpty { externalCommandsMenu.addItem(.separator()) }
        let manage = externalCommandsMenu.addItem(
            withTitle: L("extcmd.manage", "Manage Commands…"),
            action: #selector(manageExternalCommandsMenu), keyEquivalent: "")
        manage.target = self
    }

    @objc private func runExternalCommandMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let command = externalCommands.first(where: { $0.id == id })
        else { return }
        runExternalCommand(command)
    }
    @objc private func manageExternalCommandsMenu() { showExternalCommandsManager() }
}
