import AppKit
import PathemEngine

/// The in-app Release Notes window: a plain, scrollable rendering of the bundled `CHANGELOG.md`,
/// newest version first. Opened on demand from Help > Release Notes (and reachable from the
/// command palette). Never shown automatically -- the changelog lives in the app, but reading it
/// is always the user's choice.
@MainActor
final class ChangelogWindowController: NSWindowController {
    static let shared = ChangelogWindowController()

    private let textView = NSTextView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("changelog.title", "Release Notes")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        super.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 20)
        scroll.documentView = textView
        window.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Load the changelog fresh and bring the window to the front.
    func present() {
        textView.textStorage?.setAttributedString(Self.renderedChangelog())
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Build the attributed release-notes text from the bundled CHANGELOG.md. Returns a short
    /// "up to date" line if the file is missing (belt and suspenders -- it's always bundled).
    private static func renderedChangelog() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        out.append(
            NSAttributedString(
                string: L("changelog.heading", "What's New in Pathem") + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ]))
        out.append(
            NSAttributedString(
                string: L("changelog.youAreOn", "You are on version %@.").replacingOccurrences(
                    of: "%@", with: version) + "\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))

        guard let url = pathemResourceBundle.url(forResource: "CHANGELOG", withExtension: "md"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else {
            out.append(
                NSAttributedString(
                    string: L("changelog.unavailable", "Release notes aren't available in this build."),
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            return out
        }

        let bullet = NSMutableParagraphStyle()
        bullet.headIndent = 16
        bullet.firstLineHeadIndent = 4
        bullet.paragraphSpacing = 3

        for entry in ChangelogParser.parse(markdown) {
            var header = entry.version
            if let date = entry.date { header += "   " + date }
            out.append(
                NSAttributedString(
                    string: header + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
                    ]))
            for note in entry.notes {
                out.append(
                    NSAttributedString(
                        string: "•  " + note + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 13),
                            .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: bullet,
                        ]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        }
        return out
    }
}
