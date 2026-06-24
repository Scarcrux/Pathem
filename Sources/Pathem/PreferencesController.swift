import AppKit
import PathemEngine

/// A small preferences panel: list density, font size, alternating rows, and
/// whether semantic search OCRs image contents. Each change is reported live via
/// `onChange`; the browser applies and persists it.
@MainActor
final class PreferencesController: NSObject {
    private let panel: NSPanel
    private let densityPopup = NSPopUpButton()
    private let fontStepper = NSStepper()
    private let fontValue = NSTextField(labelWithString: "13")
    private let alternatingCheck = NSButton(checkboxWithTitle: L("prefs.alternatingRows", "Alternating row colors"), target: nil, action: nil)
    private let ocrCheck = NSButton(checkboxWithTitle: L("prefs.searchImageContents", "Search image contents (OCR, slower)"), target: nil, action: nil)

    private var prefs = Preferences.default
    private var onChange: ((Preferences) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = L("prefs.title", "Preferences")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        densityPopup.addItems(withTitles: [L("prefs.densityComfortable", "Comfortable"), L("prefs.densityCompact", "Compact")])
        densityPopup.target = self
        densityPopup.action = #selector(changed)

        fontStepper.minValue = 10
        fontStepper.maxValue = 18
        fontStepper.increment = 1
        fontStepper.valueWraps = false
        fontStepper.target = self
        fontStepper.action = #selector(changed)
        fontValue.translatesAutoresizingMaskIntoConstraints = false
        fontValue.widthAnchor.constraint(equalToConstant: 24).isActive = true

        for check in [alternatingCheck, ocrCheck] {
            check.target = self
            check.action = #selector(changed)
        }

        let form = NSStackView(views: [
            row(L("prefs.densityLabel", "Density"), densityPopup),
            row(L("prefs.fontSizeLabel", "Font size"), fontStepper, fontValue),
            row("", alternatingCheck),
            row("", ocrCheck),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            form.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
        ])
    }

    private func row(_ title: String, _ views: NSView...) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let stack = NSStackView(views: [label] + views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    func present(_ prefs: Preferences, over window: NSWindow, onChange: @escaping (Preferences) -> Void) {
        self.prefs = prefs
        self.onChange = onChange
        densityPopup.selectItem(at: prefs.density == .compact ? 1 : 0)
        fontStepper.integerValue = prefs.fontSize
        fontValue.stringValue = "\(prefs.fontSize)"
        alternatingCheck.state = prefs.alternatingRows ? .on : .off
        ocrCheck.state = prefs.searchOCR ? .on : .off

        let frame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed() {
        prefs.density = densityPopup.indexOfSelectedItem == 1 ? .compact : .comfortable
        prefs.fontSize = fontStepper.integerValue
        fontValue.stringValue = "\(prefs.fontSize)"
        prefs.alternatingRows = alternatingCheck.state == .on
        prefs.searchOCR = ocrCheck.state == .on
        onChange?(prefs)
    }
}
