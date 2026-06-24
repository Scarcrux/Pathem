import Foundation

/// The command bus that the whole superuser surface binds to (DESIGN.md
/// section 10). Every user action is a named Command; toolbars, keybindings,
/// menus, the command palette, and the AI command bar all dispatch by id rather
/// than calling code directly. Keeping this as the single spine means every new
/// feature gains a palette entry and a bindable key for free.
///
/// Main-actor isolated because handlers touch UI. Handlers are supplied by the
/// app layer; the registry itself carries no AppKit dependency.
@MainActor
public final class CommandRegistry {
    public struct Command {
        public let id: String
        public let title: String
        public let isEnabled: () -> Bool
        public let run: () -> Void

        public init(
            id: String, title: String,
            isEnabled: @escaping () -> Bool = { true },
            run: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.isEnabled = isEnabled
            self.run = run
        }
    }

    private var commands: [String: Command] = [:]
    private var order: [String] = []

    public init() {}

    /// Register (or replace) a command. Registration order is preserved for
    /// display in palettes and menus.
    public func register(_ command: Command) {
        if commands[command.id] == nil { order.append(command.id) }
        commands[command.id] = command
    }

    public func command(_ id: String) -> Command? { commands[id] }

    /// Remove a command (e.g. a deleted template's command) so it stops appearing
    /// in the palette and the shortcut editor.
    public func unregister(_ id: String) {
        commands[id] = nil
        order.removeAll { $0 == id }
    }

    /// All commands in registration order.
    public var all: [Command] { order.compactMap { commands[$0] } }

    /// Run a command by id if it exists and is currently enabled. Returns
    /// whether it ran (so a caller can fall back, e.g. beep).
    @discardableResult
    public func perform(_ id: String) -> Bool {
        guard let command = commands[id], command.isEnabled() else { return false }
        command.run()
        return true
    }
}
