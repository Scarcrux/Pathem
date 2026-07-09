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
    /// Appearance + shell. Applied live (colors/font) on set; the shell takes
    /// effect on the next launch.
    public var theme: TerminalTheme = .system { didSet { applyTheme() } }

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
        applyTheme()
    }

    /// Apply the current theme's font and colors to the live terminal. Empty
    /// colors fall back to system defaults; an empty/!=16 palette leaves
    /// SwiftTerm's built-in ANSI colors.
    private func applyTheme() {
        let size = CGFloat(theme.fontSize)
        term.font = NSFont(name: theme.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        term.nativeForegroundColor = TerminalTheme.nsColor(theme.foreground) ?? .textColor
        term.nativeBackgroundColor = TerminalTheme.nsColor(theme.background) ?? .textBackgroundColor
        if let cursor = TerminalTheme.nsColor(theme.cursor) { term.caretColor = cursor }
        let palette = theme.ansi.compactMap { TerminalTheme.termColor($0) }
        if palette.count == 16 { term.installColors(palette) }
    }

    /// Start the configured (or login) shell in `directory`, once. No-op if running.
    public func ensureStarted(in directory: URL) {
        guard !isRunning else { return }
        let shell = theme.shellPath.isEmpty
            ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            : theme.shellPath
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

    /// Run `command` in the shell (clears any half-typed line, then sends it with a newline). Used
    /// by the commander command line. Skips a full-screen TUI so it never injects into one.
    public func runInline(_ command: String, in directory: URL) {
        ensureStarted(in: directory)
        guard !term.getTerminal().isCurrentBufferAlternate else { return }
        term.send(txt: "\u{15}\(command)\n")
    }

    /// Type `command` into the shell without running it (no trailing newline), clearing any
    /// half-typed line first, so the user can review it and press Return. Used for the privileged
    /// `sudo chown` route: the shell prompts for the password interactively. Skips a full-screen
    /// TUI so it never injects into vim/less/ssh.
    public func typeCommand(_ command: String, in directory: URL) {
        ensureStarted(in: directory)
        guard !term.getTerminal().isCurrentBufferAlternate else { return }
        term.send(txt: "\u{15}\(command)")
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
