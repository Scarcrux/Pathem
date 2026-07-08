import AppKit
import PathemEngine

/// Runs an external command off the main thread and shows its combined output in a panel, with a
/// Stop button (terminates the process) while it runs and a status line for the exit code.
@MainActor
final class ExternalCommandOutputController: NSObject {
    /// Holds the Process across the actor boundary: created on the main actor, run in a detached
    /// task, and terminated from the main actor by Stop. terminate() is safe from any thread.
    private final class ProcessBox: @unchecked Sendable { let process = Process() }

    private let panel: NSPanel
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton()
    private var box: ProcessBox?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    /// Show the panel, run `command` on `files` in `directory` off-main, then display its output.
    func run(_ command: ExternalCommand, files: [URL], directory: URL) {
        panel.title = command.name
        textView.string = ""
        statusLabel.stringValue = L("extcmd.running", "Running…")
        statusLabel.textColor = .secondaryLabelColor
        stopButton.isEnabled = true
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)

        let box = ProcessBox()
        self.box = box
        Task { @MainActor in
            let output = await Task.detached(priority: .userInitiated) {
                ExternalCommandRunner.run(command, files: files, directory: directory, process: box.process)
            }.value
            guard self.box === box else { return }  // a newer run replaced us
            self.box = nil
            self.textView.string = output.text
            self.textView.scrollToEndOfDocument(nil)
            self.stopButton.isEnabled = false
            self.statusLabel.stringValue =
                output.succeeded
                ? L("extcmd.finished", "Finished")
                : String(format: L("extcmd.exitCode", "Exited with code %d"), Int(output.exitCode))
            self.statusLabel.textColor = output.succeeded ? .secondaryLabelColor : .systemRed
        }
    }

    @objc private func stop() { box?.process.terminate() }

    private func build() {
        panel.title = L("extcmd.outputTitle", "Command Output")
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = [.width]

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stopButton.title = L("extcmd.stop", "Stop")
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stop)
        let close = NSButton(title: L("common.close", "Close"), target: panel, action: #selector(NSWindow.performClose(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        let bar = NSStackView(views: [statusLabel, NSView(), stopButton, close])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }
}
