import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// The docked preview pane's content. For PDFs it uses a real PDFKit `PDFView` -- continuous
/// scrolling, zoom in/out + fit, and printing -- with a small control strip; for everything else
/// it falls back to the system `QLPreviewView` (which already scrolls and pinch-zooms images and
/// most types). Swapping to PDFView is what gives PDFs the print/zoom/scroll basics that Quick
/// Look alone doesn't surface.
@MainActor
final class DocumentPreviewView: NSView {
    private let quickLook = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    private let pdfView = PDFMarkupView()
    private let controls = NSStackView()
    /// The second toolbar row: the markup tools, shown only while markup mode is on.
    private let markupBar = NSStackView()
    private let markupToggle = NSButton()
    private let saveButton = NSButton()
    private let colorWell = NSColorWell()
    /// The PDF container (controls + markup bar + PDFView), shown only for PDFs.
    private let pdfContainer = NSView()
    private var currentURL: URL?
    private var isEdited = false
    /// The modal-tool buttons, keyed so the active one can draw pressed.
    private var toolButtons: [PDFMarkupView.Tool: NSButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        quickLook.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quickLook)
        NSLayoutConstraint.activate([
            quickLook.leadingAnchor.constraint(equalTo: leadingAnchor),
            quickLook.trailingAnchor.constraint(equalTo: trailingAnchor),
            quickLook.topAnchor.constraint(equalTo: topAnchor),
            quickLook.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        pdfView.autoScales = true  // fit width; user can then zoom in/out
        pdfView.displayMode = .singlePageContinuous  // scroll through pages
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        controls.orientation = .horizontal
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        controls.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, tip, action) in [
            ("minus.magnifyingglass", L("preview.zoomOut", "Zoom Out"), #selector(zoomOut)),
            ("plus.magnifyingglass", L("preview.zoomIn", "Zoom In"), #selector(zoomIn)),
            ("arrow.up.left.and.arrow.down.right", L("preview.fit", "Fit Width"), #selector(fitWidth)),
            ("printer", L("preview.print", "Print"), #selector(printDocument)),
        ] {
            controls.addArrangedSubview(iconButton(symbol, tip, action))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(spacer)  // push the markup controls to the right

        markupToggle.image = NSImage(
            systemSymbolName: "pencil.tip.crop.circle",
            accessibilityDescription: L("preview.markup", "Markup"))
        markupToggle.bezelStyle = .texturedRounded
        markupToggle.setButtonType(.pushOnPushOff)
        markupToggle.target = self
        markupToggle.action = #selector(toggleMarkup)
        markupToggle.toolTip = L("preview.markup", "Markup")
        markupToggle.setAccessibilityLabel(L("preview.markup", "Markup"))
        controls.addArrangedSubview(markupToggle)

        saveButton.image = NSImage(
            systemSymbolName: "square.and.arrow.down", accessibilityDescription: L("preview.save", "Save"))
        saveButton.bezelStyle = .texturedRounded
        saveButton.target = self
        saveButton.action = #selector(saveMarkup)
        saveButton.toolTip = L("preview.save", "Save")
        saveButton.setAccessibilityLabel(L("preview.save", "Save"))
        saveButton.isHidden = true
        controls.addArrangedSubview(saveButton)

        buildMarkupBar()

        pdfContainer.translatesAutoresizingMaskIntoConstraints = false
        let topBar = NSStackView(views: [controls, markupBar])
        topBar.orientation = .vertical
        topBar.spacing = 0
        topBar.alignment = .leading
        topBar.distribution = .fill
        topBar.translatesAutoresizingMaskIntoConstraints = false
        markupBar.isHidden = true  // an NSStackView collapses a hidden arranged subview's height
        pdfContainer.addSubview(topBar)
        pdfContainer.addSubview(pdfView)
        addSubview(pdfContainer)
        NSLayoutConstraint.activate([
            pdfContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfContainer.topAnchor.constraint(equalTo: topAnchor),
            pdfContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: pdfContainer.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            pdfView.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor),
        ])
        pdfContainer.isHidden = true

        pdfView.onDocumentEdited = { [weak self] in self?.markEdited() }
    }

    /// A small textured toolbar button carrying an SF Symbol.
    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
            target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    /// Build the markup tool row: selection markup (highlight/underline/strike), the modal drawing
    /// tools, a color well, and undo. Selection markup are one-shot actions; the drawing tools are
    /// modal toggles that stay armed until re-picked.
    private func buildMarkupBar() {
        markupBar.orientation = .horizontal
        markupBar.spacing = 4
        markupBar.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 6, right: 8)
        markupBar.translatesAutoresizingMaskIntoConstraints = false

        // Selection markup (apply to the current text selection).
        for (symbol, tip, action) in [
            ("highlighter", L("markup.highlight", "Highlight"), #selector(applyHighlight)),
            ("underline", L("markup.underline", "Underline"), #selector(applyUnderline)),
            ("strikethrough", L("markup.strikethrough", "Strikethrough"), #selector(applyStrikethrough)),
        ] {
            markupBar.addArrangedSubview(iconButton(symbol, tip, action))
        }
        markupBar.addArrangedSubview(divider())

        // Modal drawing tools.
        let tools: [(String, String, PDFMarkupView.Tool)] = [
            ("scribble", L("markup.draw", "Draw"), .draw),
            ("signature", L("markup.signature", "Signature"), .signature),
            ("rectangle", L("markup.rectangle", "Rectangle"), .rectangle),
            ("oval", L("markup.oval", "Oval"), .oval),
            ("line.diagonal", L("markup.line", "Line"), .line),
            ("arrow.up.right", L("markup.arrow", "Arrow"), .arrow),
            ("textformat", L("markup.text", "Text"), .text),
            ("note.text", L("markup.note", "Note"), .note),
        ]
        for (symbol, tip, tool) in tools {
            let button = iconButton(symbol, tip, #selector(selectTool(_:)))
            button.setButtonType(.pushOnPushOff)
            button.tag = toolTagBase + toolIndex(tool)
            toolButtons[tool] = button
            markupBar.addArrangedSubview(button)
        }
        markupBar.addArrangedSubview(divider())

        colorWell.color = pdfView.markupColor
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.toolTip = L("markup.color", "Color")
        colorWell.setAccessibilityLabel(L("markup.color", "Color"))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        markupBar.addArrangedSubview(colorWell)

        markupBar.addArrangedSubview(iconButton("arrow.uturn.backward", L("markup.undo", "Undo"), #selector(undoMarkup)))
        markupBar.addArrangedSubview(iconButton("arrow.uturn.forward", L("markup.redo", "Redo"), #selector(redoMarkup)))
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    /// A stable, order-independent tag for a modal tool so `selectTool(_:)` can recover it.
    private let toolTagBase = 4200
    private let toolOrder: [PDFMarkupView.Tool] = [
        .draw, .signature, .rectangle, .oval, .line, .arrow, .text, .note,
    ]
    private func toolIndex(_ tool: PDFMarkupView.Tool) -> Int { toolOrder.firstIndex(of: tool) ?? 0 }

    /// Show `url` in the pane: a PDFView for PDFs, else the system Quick Look preview. `nil` clears.
    /// A corrupt or encrypted PDF (nil document, or one that loads locked) falls through to Quick
    /// Look, which shows a corrupt file gracefully and prompts for an encrypted PDF's password --
    /// where PDFView would just render blank behind dead zoom/print buttons.
    func show(_ url: URL?) {
        offerToSaveIfEdited()  // don't silently drop markup when navigating away
        currentURL = url
        if let url, Self.isPDF(url), let document = PDFDocument(url: url), !document.isLocked {
            pdfView.document = document
            pdfView.autoScales = true
            pdfContainer.isHidden = false
            quickLook.isHidden = true
            quickLook.previewItem = nil  // release the previewed file
            resetMarkupState()
            // The document is often set before the view has its final frame, so autoScales computes
            // against a zero size and the page renders blank. Re-lay-out once we're sized.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pdfView.document === document else { return }
                self.pdfView.autoScales = true
                self.pdfView.layoutDocumentView()
                // Start at the top of the first page. goToFirstPage leaves a short viewport parked on
                // the page's vertical centre, so a document whose text sits up top can look blank.
                if let first = document.page(at: 0) {
                    let mediaTop = first.bounds(for: .mediaBox).height
                    self.pdfView.go(to: PDFDestination(page: first, at: CGPoint(x: 0, y: mediaTop)))
                }
            }
        } else {
            pdfView.document = nil
            pdfContainer.isHidden = true
            quickLook.isHidden = false
            quickLook.previewItem = url as NSURL?
        }
    }

    /// Clear the edited flag and disarm any active tool when a fresh document loads.
    private func resetMarkupState() {
        isEdited = false
        pdfView.activeTool = .none
        for button in toolButtons.values { button.state = .off }
        saveButton.isHidden = true
    }

    static func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .pdf) ?? false
    }

    /// Types worth opening in the other pane's viewer: PDFs and images (the rest belong in their
    /// own app). PDFs get the PDFView; images ride the Quick Look fallback.
    static func isViewable(_ url: URL) -> Bool {
        if isPDF(url) { return true }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false
    }

    /// Whether the PDF path (not Quick Look) is currently showing -- for the smoke check.
    var debugShowingPDF: Bool { !pdfContainer.isHidden }

    @objc private func zoomIn() { pdfView.zoomIn(nil) }
    @objc private func zoomOut() { pdfView.zoomOut(nil) }
    @objc private func fitWidth() { pdfView.autoScales = true }

    @objc private func printDocument() {
        guard pdfView.document != nil else { NSSound.beep(); return }
        pdfView.print(with: .shared, autoRotate: true, pageScaling: .pageScaleDownToFit)
    }

    // MARK: Markup

    @objc private func toggleMarkup() {
        let on = markupToggle.state == .on
        markupBar.isHidden = !on
        if !on {
            pdfView.activeTool = .none
            for button in toolButtons.values { button.state = .off }
        }
    }

    @objc private func selectTool(_ sender: NSButton) {
        let tool = toolOrder[max(0, sender.tag - toolTagBase)]
        // AppKit toggles the pushOnPushOff button before firing: state .on means "arm this tool",
        // .off (re-clicked the armed tool) means "disarm". Reflect the choice on every tool button.
        let newTool: PDFMarkupView.Tool = (sender.state == .on) ? tool : .none
        pdfView.activeTool = newTool
        for (buttonTool, button) in toolButtons { button.state = (buttonTool == newTool) ? .on : .off }
    }

    @objc private func colorChanged() {
        pdfView.markupColor = colorWell.color
    }

    @objc private func applyHighlight() { pdfView.markUpSelection(.highlight) }
    @objc private func applyUnderline() { pdfView.markUpSelection(.underline) }
    @objc private func applyStrikethrough() { pdfView.markUpSelection(.strikeOut) }
    @objc private func undoMarkup() { pdfView.undoMarkup() }
    @objc private func redoMarkup() { pdfView.redoMarkup() }

    private func markEdited() {
        isEdited = true
        saveButton.isHidden = false
        saveButton.contentTintColor = .controlAccentColor  // a subtle "unsaved" cue
    }

    /// Write the annotated document back over the original file. Returns success for the smoke check.
    @discardableResult
    @objc func saveMarkup() -> Bool {
        guard let url = currentURL, let document = pdfView.document else { return false }
        guard document.write(to: url) else {
            let alert = NSAlert()
            alert.messageText = L("markup.saveFailed", "Couldn't save the PDF.")
            alert.informativeText = url.path
            alert.runModal()
            return false
        }
        isEdited = false
        saveButton.contentTintColor = nil
        return true
    }

    /// When leaving an edited document, ask whether to save. There is no Cancel: navigation has
    /// already been decided by the caller, so the choice is only Save or Discard.
    private func offerToSaveIfEdited() {
        guard isEdited, currentURL != nil else { return }
        let alert = NSAlert()
        alert.messageText = L("markup.saveChanges", "Save your markup?")
        alert.informativeText = currentURL?.lastPathComponent ?? ""
        alert.addButton(withTitle: L("preview.save", "Save"))
        alert.addButton(withTitle: L("markup.discard", "Discard"))
        if alert.runModal() == .alertFirstButtonReturn { saveMarkup() }
        isEdited = false
    }

    // MARK: Test hooks

    /// Add a highlight and save, for the markup round-trip smoke check.
    @discardableResult
    func debugMarkUpAndSave(rect: CGRect) -> Bool {
        guard pdfView.debugAddHighlight(rect) else { return false }
        return saveMarkup()
    }

    /// Draw an ink stroke through `points` (page coordinates) and save, for the ink coordinate-space
    /// render check (PATHEM_INK_TEST).
    @discardableResult
    func debugInkAndSave(points: [CGPoint]) -> Bool {
        guard pdfView.debugAddInk(points) != nil else { return false }
        return saveMarkup()
    }

    /// Draw one of each shape / line / arrow at distinct known spots and save, for the render check
    /// (PATHEM_MARKUP_TEST) that confirms every modal tool lands where its drag would.
    @discardableResult
    func debugDrawShapesAndSave() -> Bool {
        pdfView.debugAddShape(.rectangle, from: CGPoint(x: 80, y: 650), to: CGPoint(x: 250, y: 720))
        pdfView.debugAddShape(.oval, from: CGPoint(x: 320, y: 650), to: CGPoint(x: 500, y: 720))
        pdfView.debugAddShape(.line, from: CGPoint(x: 80, y: 560), to: CGPoint(x: 500, y: 560))
        pdfView.debugAddShape(.arrow, from: CGPoint(x: 80, y: 480), to: CGPoint(x: 420, y: 480))
        return saveMarkup()
    }

    /// Lay a tasteful set of annotations over the shown document (a highlight over a body line, an
    /// arrow pointing at it, and a margin sticky note) for the marketing shot, so the viewer reads as
    /// markup in use. Coordinates are tuned to the demo brief's second body line so the highlight
    /// lands on text (translucent), not an opaque bar over blank space -- this reproduces the shipped
    /// view-markup.webp figure. Keep it in sync with that asset if the demo text changes.
    func debugAddSampleMarkup() {
        pdfView.markupColor = .systemYellow
        pdfView.debugAddHighlight(CGRect(x: 62, y: 636, width: 486, height: 16))  // over a full body line
        pdfView.markupColor = .systemRed
        pdfView.debugAddShape(.arrow, from: CGPoint(x: 448, y: 556), to: CGPoint(x: 214, y: 632))  // point at it
        pdfView.markupColor = .systemBlue
        pdfView.debugAddText("revisit", at: CGPoint(x: 560, y: 652), note: true)  // sticky note in the margin
        pdfView.markupColor = .systemYellow  // leave the color well on the default
    }

    /// Add the sample markup and save, for the marketing-figure render (PATHEM_MARKUP_RENDER).
    @discardableResult
    func debugAddSampleMarkupAndSave() -> Bool {
        debugAddSampleMarkup()
        return saveMarkup()
    }

    /// Place a free-text box and a sticky note (in a legible color) and save, for the render check
    /// (PATHEM_TEXT_TEST) of the two tools whose modal prompt can't run headlessly.
    @discardableResult
    func debugDrawTextAndSave() -> Bool {
        pdfView.markupColor = .systemBlue
        pdfView.debugAddText("Reviewed by design", at: CGPoint(x: 90, y: 660), note: false)
        pdfView.debugAddText("Check this section", at: CGPoint(x: 90, y: 560), note: true)
        return saveMarkup()
    }

    /// Drive the markup toggle and a tool button through their real actions, for the tool-state
    /// smoke check (guards the tag-based `selectTool` mapping).
    var debugMarkupVisible: Bool { !markupBar.isHidden }
    var debugActiveTool: PDFMarkupView.Tool { pdfView.activeTool }
    func debugToggleMarkup(_ on: Bool) {
        markupToggle.state = on ? .on : .off
        toggleMarkup()
    }
    func debugPickTool(_ tool: PDFMarkupView.Tool) {
        guard let button = toolButtons[tool] else { return }
        button.state = (button.state == .on) ? .off : .on  // mimic the pushOnPushOff flip AppKit does on click
        selectTool(button)
    }
}

/// A full-pane document viewer shown when a file is opened in the other pane: a header (filename +
/// Done) over a `DocumentPreviewView`. Dismissed by Done, Escape, or the pane navigating away.
@MainActor
final class PaneDocumentViewer: NSView {
    var onDone: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let viewer = DocumentPreviewView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: L("viewer.done", "Done"), target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"  // Escape
        done.setAccessibilityLabel(L("viewer.done", "Done"))
        done.translatesAutoresizingMaskIntoConstraints = false

        viewer.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(done)
        addSubview(header)
        addSubview(viewer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -8),
            viewer.topAnchor.constraint(equalTo: header.bottomAnchor),
            viewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ url: URL) {
        titleLabel.stringValue = url.lastPathComponent
        viewer.show(url)
    }

    /// Turn on markup mode, arm the Draw tool, and lay down sample annotations, for the marquee shot
    /// (PATHEM_MAIN_MODE=markup).
    func debugEnableMarkup() {
        viewer.debugToggleMarkup(true)
        viewer.debugPickTool(.draw)
        viewer.debugAddSampleMarkup()
    }

    @objc private func dismiss() { onDone?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?() } else { super.keyDown(with: event) }  // 53 = Escape
    }
}
