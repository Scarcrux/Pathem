import AppKit
import PathomEngine

// Minimal AppKit entry point. This is a stub window proving the app target
// builds and runs; the real file list (view-based NSTableView over the
// engine's FileEntry array) is the next milestone (DESIGN.md §5, "Gate A").
@main
@MainActor
enum PathomApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pathom"
        window.center()

        // Smoke test that the engine links and runs: list the home directory.
        let count = (try? FoundationEnumerator()
            .entries(of: FileManager.default.homeDirectoryForCurrentUser, includingHidden: false)
            .count) ?? 0
        let label = NSTextField(labelWithString: "Pathom — \(count) items in your home folder")
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(label)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }

        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
