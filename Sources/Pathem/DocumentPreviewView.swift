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
    func show(_ url: URL?) {
        currentURL = url
        if let url, Self.isPDF(url), let document = PDFDocument(url: url) {
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
