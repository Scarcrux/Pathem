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
    private let pdfView = PDFView()
    private let controls = NSStackView()
    /// The PDF container (controls + PDFView), shown only for PDFs.
    private let pdfContainer = NSView()
    private var currentURL: URL?

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
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            controls.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(spacer)  // left-align the buttons

        pdfContainer.translatesAutoresizingMaskIntoConstraints = false
        pdfContainer.addSubview(controls)
        pdfContainer.addSubview(pdfView)
        addSubview(pdfContainer)
        NSLayoutConstraint.activate([
            pdfContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfContainer.topAnchor.constraint(equalTo: topAnchor),
            pdfContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor),
            controls.topAnchor.constraint(equalTo: pdfContainer.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: controls.bottomAnchor),
            pdfView.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor),
        ])
        pdfContainer.isHidden = true
    }

    /// Show `url` in the pane: a PDFView for PDFs, else the system Quick Look preview. `nil` clears.
    /// A corrupt or encrypted PDF (nil document, or one that loads locked) falls through to Quick
    /// Look, which shows a corrupt file gracefully and prompts for an encrypted PDF's password --
    /// where PDFView would just render blank behind dead zoom/print buttons.
    func show(_ url: URL?) {
        currentURL = url
        if let url, Self.isPDF(url), let document = PDFDocument(url: url), !document.isLocked {
            pdfView.document = document
            pdfView.autoScales = true
            pdfContainer.isHidden = false
            quickLook.isHidden = true
            quickLook.previewItem = nil  // release the previewed file
        } else {
            pdfView.document = nil
            pdfContainer.isHidden = true
            quickLook.isHidden = false
            quickLook.previewItem = url as NSURL?
        }
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

    @objc private func dismiss() { onDone?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?() } else { super.keyDown(with: event) }  // 53 = Escape
    }
}
