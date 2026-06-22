import AppKit
import Darwin

// SwiftTerm is imported pre-concurrency: its delegate protocol predates Swift 6
// actor isolation, but SwiftTerm always calls these callbacks on the main
// thread, so a @MainActor host is safe.
@preconcurrency import SwiftTerm

/// An embedded terminal pane backed by SwiftTerm's `LocalProcessTerminalView`.
/// It hosts a real login shell over a pseudo-terminal (interactive: vim, ssh,
/// colors, REPLs) and can follow the file browser's active folder. This is the
/// only place SwiftTerm is referenced, so the feature (and the dependency) is
/// removable by dropping the PathemTerminal target.
@MainActor
public final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    /// The view to embed in the window. The terminal fills it.
    public let view = NSView()
    private let term = LocalProcessTerminalView(frame: .zero)

    /// Whether a shell process is currently running.
    public private(set) var isRunning = false
    /// Reports the shell's title (OSC), e.g. for a pane header.
    public var onTitleChange: ((String) -> Void)?

    public override init() {
        super.init()
        term.processDelegate = self
        term.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(term)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: view.topAnchor),
            term.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            term.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Start the user's login shell in `directory`, once. No-op if already running.
    public func ensureStarted(in directory: URL) {
        guard !isRunning else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        // A leading "-" in argv[0] makes it a login shell (loads the user profile),
        // matching Terminal.app.
        term.startProcess(
            executable: shell, args: [], environment: env,
            execName: "-\(shellName)", currentDirectory: directory.path)
        isRunning = true
    }

    /// Send a `cd` so the shell follows the browser. Only meaningful while running.
    /// Skips when a full-screen program (vim, less, htop, an ssh session) owns the
    /// alternate screen, so navigation never injects keystrokes into a TUI. A
    /// leading Ctrl-U clears any half-typed command line first, so following the
    /// folder can't execute a mangled command.
    public func changeDirectory(to url: URL) {
        guard isRunning, !term.getTerminal().isCurrentBufferAlternate else { return }
        term.send(txt: "\u{15}cd \(Self.shellQuote(url.path))\n")
    }

    public func focus() {
        term.window?.makeFirstResponder(term)
    }

    /// Hang up the shell and its whole process group, like closing a real
    /// terminal window. SwiftTerm only sends a lone SIGTERM to the leader, which
    /// an interactive shell can ignore, so signal the process group with SIGHUP
    /// (the shell then HUPs its jobs) and ask SwiftTerm to terminate as a backstop.
    public func shutdown() {
        guard isRunning else { return }
        isRunning = false
        let pid = term.process.shellPid
        if pid > 0 { kill(-pid, SIGHUP) }
        term.terminate()
    }

    /// Single-quote a path for the shell, escaping embedded single quotes.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: LocalProcessTerminalViewDelegate
    // The protocol predates Swift 6 isolation, so the witnesses are nonisolated;
    // SwiftTerm invokes them on the main thread, so we assume main-actor inside.

    public nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { onTitleChange?(title) }
    }

    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            isRunning = false
            let code = exitCode.map { " (\($0))" } ?? ""
            term.feed(text: "\r\n[shell exited\(code)]. Reopen the terminal to start a new one.\r\n")
        }
    }
}
