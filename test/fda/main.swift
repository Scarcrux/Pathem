import AppKit

func L(_ key: String, _ fallback: String) -> String { fallback }

@MainActor
final class ThemeManager {
    static let shared = ThemeManager()
    let accent = NSColor.systemBlue
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    private let guide = FullDiskAccessGuide()
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let key = "pathem.fdaGuideDismissed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.orderFront(nil)
        present()
        guard
            let guideWindow = NSApp.windows.first(where: {
                $0.title == "Full Disk Access" && ($0.isVisible || $0.sheetParent === window)
            })
        else { exit(2) }
        if CommandLine.arguments.contains("--reopen") {
            guard let notNow = button("Not Now", in: guideWindow.contentView) else { exit(3) }
            notNow.performClick(nil)
            guard UserDefaults.standard.bool(forKey: key) else { exit(4) }
            present()
            guard guideWindow.isVisible else { exit(5) }
            print("REOPENED")
        }
        let child = guideWindow.parent === window
        print(
            "READY \(ProcessInfo.processInfo.processIdentifier) sheet=\(window.attachedSheet != nil) child=\(child)"
        )
        fflush(stdout)
    }

    private func present() {
        guide.present(over: window) { [self] in UserDefaults.standard.set(true, forKey: key) }
    }

    private func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let control = view as? NSButton, control.title == title { return control }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("TERMINATED dismissed=\(UserDefaults.standard.bool(forKey: key))")
        fflush(stdout)
    }
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--quit", let pid = Int32(arguments[2]) {
        guard let target = NSRunningApplication(processIdentifier: pid),
            target.bundleURL?.path == ProcessInfo.processInfo.environment["FDA_PROBE_BUNDLE"]
        else { exit(6) }
        exit(target.terminate() ? 0 : 7)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Probe()
    app.delegate = delegate
    app.run()
}
