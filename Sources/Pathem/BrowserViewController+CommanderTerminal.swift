import AppKit
import PathemTerminal

// The embedded terminal drawer and the orthodox Commander F-key/command-line bar: show/hide,
// size the drawer, run a command line, and keep the prompt/follow-folder state in sync. Split
// out of BrowserViewController.
@MainActor
extension BrowserViewController {

    /// Show or hide the embedded terminal drawer. On first show it starts a login
    /// shell in the active folder and gives the drawer a reasonable height.
    /// Show/hide the commander bar (orthodox F-key bar + command line) across the window bottom.
    /// Bind the Commander F3–F8 buttons to the user's chosen commands (or the defaults).
    func applyCommanderCommands() {
        commanderBar.commandIDs =
            prefs.commanderCommands.count == 6
            ? prefs.commanderCommands : CommanderBar.defaultCommandIDs
    }

    func toggleCommander() {
        let show = commanderBar.isHidden
        commanderBar.isHidden = !show
        if show {
            shelf.view.isHidden = true  // the commander bar takes the bottom slot
            shelfHiddenConstraint?.isActive = false
            shelfShownConstraint?.isActive = false
            commanderShownConstraint?.isActive = true
            commanderBar.setPrompt(activePane?.currentURL.lastPathComponent ?? "")
            commanderBar.focusCommandLine()
        } else {
            commanderShownConstraint?.isActive = false
            shelfHiddenConstraint?.isActive = true
        }
        view.layoutSubtreeIfNeeded()
    }

    /// Run a commander command line in the embedded terminal (revealed if hidden), in the folder.
    func runCommanderCommand(_ command: String) {
        let folder = activePane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        if terminal.view.isHidden { toggleTerminal() }
        terminal.runInline(command, in: folder)
    }

    /// Keep the commander prompt in sync with the active folder (when the bar is showing).
    func updateCommanderPrompt() {
        guard !commanderBar.isHidden else { return }
        commanderBar.setPrompt(activePane?.currentURL.lastPathComponent ?? "")
    }

    func toggleTerminal() {
        let show = terminal.view.isHidden
        terminal.view.isHidden = !show
        // Hiding or un-hiding an arranged subview does not make NSSplitView redistribute its
        // space. On macOS 27.2.1 both halves were left at zero height (a blank window), and
        // setPosition cannot recover from that; hiding again did not give the browser its
        // space back either. Ask the split to lay its subviews out again first.
        vSplit.adjustSubviews()
        UserDefaults.standard.set(show, forKey: "pathem.terminalVisible")
        guard show else { return }
        terminal.ensureStarted(
            in: activePane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser)
        sizeTerminalDrawer()
        terminal.focus()
    }

    /// Give the terminal drawer a fixed height and the browser the rest. When the
    /// split has no real height yet (e.g. restoring on launch before layout), the
    /// terminal's holding priority would otherwise collapse the browser, so retry
    /// on the next runloop once the window has laid out.
    private func sizeTerminalDrawer() {
        let height = vSplit.bounds.height
        if height > 280 {
            vSplit.setPosition(height - 240, ofDividerAt: 0)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminal.view.isHidden else { return }
                let h = self.vSplit.bounds.height
                if h > 280 { self.vSplit.setPosition(h - 240, ofDividerAt: 0) }
            }
        }
    }

    /// Reveal the terminal (if hidden) and point it at the active folder. If it
    /// was already running we send a `cd`; if it had to start, it already launched
    /// in the active folder, so we skip the redundant (and racy) `cd`.
    func openTerminalHere() {
        let wasRunning = terminal.isRunning
        if terminal.view.isHidden { toggleTerminal() }
        if wasRunning, let url = activePane?.currentURL { terminal.changeDirectory(to: url) }
        terminal.focus()
    }

    /// Toggle whether the terminal follows the active folder, and persist it.
    func toggleTerminalFollows() {
        terminalFollows.toggle()
        UserDefaults.standard.set(terminalFollows, forKey: "pathem.terminalFollows")
        if terminalFollows, !terminal.view.isHidden, let url = activePane?.currentURL {
            terminal.changeDirectory(to: url)
        }
    }

    /// Hang up the embedded shell. Called on quit so no orphan shell survives.
    func terminateTerminal() { terminal.shutdown() }

}
