import Foundation

/// Pulls a text snippet out of a file so semantic search can rank by *contents*,
/// not just the name.
///
/// MVP scope: cheap, text-like files only (by extension), read up to a byte cap
/// via a file handle so we never slurp a huge or binary file. Rich formats
/// (PDF via PDFKit, Office docs, OCR via Vision) are the next layer and belong
/// above the engine — this stays pure Foundation and unit-testable.
public enum ContentExtractor {
    /// Extensions we'll read as UTF-8 text. Everything else is name-only.
    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "rtf", "tex", "log",
        "swift", "py", "js", "ts", "jsx", "tsx", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "cc", "hpp", "m", "mm", "cs", "php", "scala", "clj",
        "sh", "bash", "zsh", "pl", "lua", "r", "jl", "dart", "sql",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties",
        "csv", "tsv", "html", "htm", "xml", "css", "scss",
    ]

    /// A text snippet from `url` (up to `maxBytes`), or `nil` if it isn't a
    /// cheap text-like file. Reads only the first `maxBytes`, so large files
    /// cost the same as small ones.
    public static func snippet(of url: URL, maxBytes: Int = 8192) -> String? {
        guard textExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
