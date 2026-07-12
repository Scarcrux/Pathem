import Foundation
import PDFKit
import PathemEngine

/// The app-side PDF text extractor. PDFKit links AppKit, so it can't live in the (Foundation-only)
/// engine; the engine's ContentExtractor calls this through the PDFTextExtracting seam, injected
/// by the semantic-search controller.
struct PDFTextExtractor: PDFTextExtracting {
    func pdfText(at url: URL, maxChars: Int) -> String? {
        guard let document = PDFDocument(url: url), let string = document.string, !string.isEmpty
        else { return nil }
        return String(string.prefix(maxChars))
    }
}
