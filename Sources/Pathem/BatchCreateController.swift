import AppKit
import PathemEngine

/// A dialog to create many files or folders at once: type a literal name per line, or
/// a pattern with a {start..end} range ("Chapter {01..12}", "shot_{1..3}"). A live
/// preview shows what will be created. The work and undo happen in the browser via the
/// `create` callback; `saveTemplate` stores the current spec as a reusable template.
@MainActor
final class BatchCreateController: NSObject, NSTextViewDelegate {
    private let panel: NSPanel
    private let kindControl = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let input = NSTextView()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton()

    private var create: (([String], BatchCreate.Kind) -> Void)?
    private var saveTemplate: (([String], BatchCreate.Kind) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private var kind: BatchCreate.Kind { kindControl.selectedSegment == 1 ? .folders : .files }

    func present(
        over window: NSWindow,
        create: @escaping ([String], BatchCreate.Kind) -> Void,
        saveTemplate: @escaping ([String], BatchCreate.Kind) -> Void
    ) {
        self.create = create
        self.saveTemplate = saveTemplate
        input.string = ""
        updatePreview()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }

    private func build() {
        panel.title = L("batch.title", "Batch Create")
        kindControl.segmentCount = 2
        kindControl.setLabel(L("batch.files", "Files"), forSegment: 0)
        kindControl.setLabel(L("batch.folders", "Folders"), forSegment: 1)
        kindControl.selectedSegment = 0
        kindControl.target = self
        kindControl.action = #selector(kindChanged)

        let help = NSTextField(
            wrappingLabelWithString:
                L(
                    "batch.help",
                    "One name per line, or a pattern with a range like “Chapter {01..12}” or “shot_{1..3}”."))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.isRichText = false
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.textContainerInset = NSSize(width: 4, height: 6)
        let inputScroll = NSScrollView()
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor

        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(
            title: L("batch.saveTemplate", "Save as Template…"), target: self,
            action: #selector(saveAsTemplate))
        save.bezelStyle = .rounded
        createButton.title = L("batch.create", "Create")
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(createTapped)

        let buttons = NSStackView(views: [save, NSView(), cancel, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [kindControl, help, inputScroll, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        kindControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            inputScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func kindChanged() { updatePreview() }
    func textDidChange(_ notification: Notification) { updatePreview() }

    private func names() -> [String] { BatchCreate.expand(input.string) }

    private func updatePreview() {
        let names = self.names()
        createButton.isEnabled = !names.isEmpty
        if names.isEmpty {
            preview.stringValue = L("batch.previewEmpty", "Nothing to create yet.")
            return
        }
        let shown = names.prefix(8).joined(separator: ", ")
        let more = names.count > 8 ? "…" : ""
        preview.stringValue = String(
            format: L("batch.previewCount", "%d items: %@%@"), names.count, shown, more)
    }

    @objc private func createTapped() {
        let names = self.names()
        guard !names.isEmpty else { NSSound.beep(); return }
        create?(names, kind)
        close()
    }

    @objc private func saveAsTemplate() {
        let names = self.names()
        guard !names.isEmpty else { NSSound.beep(); return }
        saveTemplate?(names, kind)
    }

    @objc private func close() { panel.orderOut(nil) }

    /// Render the dialog to a PNG (PATHEM_PREFS_SHOT) for headless layout checks.
    func debugRender(to path: String) {
        input.string = "Chapter {01..12}"
        updatePreview()
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        content.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("BATCH SHOT: \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }
}
