import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts text from a PDF. PDFKit links AppKit, which the engine must not, so PDF extraction
/// lives in the app and the engine calls it through this seam (the app injects an implementation).
public protocol PDFTextExtracting: Sendable {
    func pdfText(at url: URL, maxChars: Int) -> String?
}

/// Pulls a text snippet out of a file so semantic search can rank by *contents*,
/// not just the name.
///
/// - text/code files: read up to `maxBytes` (cheap, via a file handle).
/// - PDFs: extracted text via an injected PDFTextExtracting (PDFKit lives in the app).
/// - images: on-device OCR (Vision) — only when `ocr` is requested, since it is
///   far slower than the others (meant for background indexing, not the
///   foreground per-search path).
///
/// All of this is on-device and free, and Foundation-only (no AppKit): the PDF path is injected.
public enum ContentExtractor {
    /// Extensions read as UTF-8 text.
    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "rtf", "tex", "log",
        "swift", "py", "js", "ts", "jsx", "tsx", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "cc", "hpp", "m", "mm", "cs", "php", "scala", "clj",
        "sh", "bash", "zsh", "pl", "lua", "r", "jl", "dart", "sql",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties",
        "csv", "tsv", "html", "htm", "xml", "css", "scss",
    ]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif",
    ]

    /// A text snippet from `url`, or `nil` if no cheap text is available.
    /// `maxBytes` caps text-file reads (and, approximately, PDF/OCR character
    /// counts). `ocr` enables Vision OCR for images (slow — off by default).
    public static func snippet(
        of url: URL, maxBytes: Int = 8192, ocr: Bool = false, pdf: PDFTextExtracting? = nil
    ) -> String? {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return text(at: url, maxBytes: maxBytes) }
        if pdfExtensions.contains(ext) { return pdf?.pdfText(at: url, maxChars: maxBytes) }
        if ocr, imageExtensions.contains(ext) { return ocrText(at: url, maxChars: maxBytes) }
        return nil
    }

    private static func text(at url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func ocrText(at url: URL, maxChars: Int) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
            let observations = request.results
        else { return nil }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(maxChars))
    }
}
