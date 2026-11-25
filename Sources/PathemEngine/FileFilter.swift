import Foundation

/// A quick-filter query for the file list. Beyond a plain name substring it understands
/// space-separated tokens (all must match): `ext:pdf` (or `.pdf`), `kind:image`
/// (folder/file/image/video/audio/document/archive/code), and size comparisons like
/// `size:>10mb`, `size:<=1kb`. Parsed once, then matched per entry. Pure, so it's tested.
public struct FileFilter: Sendable {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case folder, file, image, video, audio, document, archive, code

        var extensions: Set<String> {
            switch self {
            case .folder, .file: return []
            case .image:
                return [
                    "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
                    "raw", "cr2", "nef", "arw", "svg",
                ]
            case .video:
                return ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg"]
            case .audio: return ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus"]
            case .document:
                return [
                    "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers", "xls",
                    "xlsx", "ppt", "pptx", "csv", "epub",
                ]
            case .archive: return ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz", "dmg"]
            case .code:
                return [
                    "swift", "c", "h", "cpp", "cc", "hpp", "m", "mm", "js", "ts", "jsx", "tsx",
                    "py", "rb", "go", "rs", "java", "kt", "sh", "json", "yaml", "yml", "toml",
                    "html", "css", "sql",
                ]
            }
        }
    }

    enum Op: Sendable { case lt, le, gt, ge, eq }

    enum Token: Sendable {
        case name(String)
        case ext(String)
        case kind(Kind)
        case size(Op, Int64)
    }

    let tokens: [Token]
    public var isEmpty: Bool { tokens.isEmpty }

    public init(_ query: String) {
        tokens = query.split(whereSeparator: \.isWhitespace).compactMap(Self.parseToken)
    }

    static func parseToken(_ raw: Substring) -> Token? {
        let piece = String(raw)
        guard !piece.isEmpty else { return nil }
        let lower = piece.lowercased()
        if lower.hasPrefix("ext:") {
            let value = String(lower.dropFirst(4)).trimmingCharacters(
                in: CharacterSet(charactersIn: "."))
            return value.isEmpty ? .name(piece) : .ext(value)
        }
        if lower.hasPrefix("kind:") {
            let value = String(lower.dropFirst(5))
            return Kind(rawValue: value).map(Token.kind) ?? .name(piece)
        }
        if lower.hasPrefix("size:") {
            return parseSize(String(lower.dropFirst(5))) ?? .name(piece)
        }
        // ".pdf" shorthand for an extension (but not "." or ".." path tokens).
        if piece.hasPrefix("."), piece.count > 1, !piece.dropFirst().contains(".") {
            return .ext(String(lower.dropFirst()))
        }
        return .name(piece)
    }

    /// Parse ">10mb", "<=1kb", "=512", etc. into a comparison; nil if malformed.
    static func parseSize(_ text: String) -> Token? {
        var rest = Substring(text)
        let op: Op
        if rest.hasPrefix(">=") {
            op = .ge
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix("<=") {
            op = .le
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix(">") {
            op = .gt
            rest = rest.dropFirst(1)
        } else if rest.hasPrefix("<") {
            op = .lt
            rest = rest.dropFirst(1)
        } else if rest.hasPrefix("=") {
            op = .eq
            rest = rest.dropFirst(1)
        } else {
            op = .ge
        }  // a bare "size:10mb" means "at least"
        let scalars = rest
        let digits = scalars.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let unit = scalars.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1_000
        case "m", "mb": multiplier = 1_000_000
        case "g", "gb": multiplier = 1_000_000_000
        case "t", "tb": multiplier = 1_000_000_000_000
        default: return nil
        }
        return .size(op, Int64(number * multiplier))
    }

    public func matches(_ entry: FileEntry) -> Bool {
        for token in tokens where !Self.matches(token, entry) { return false }
        return true
    }

    static func matches(_ token: Token, _ entry: FileEntry) -> Bool {
        switch token {
        case .name(let needle):
            return entry.name.localizedCaseInsensitiveContains(needle)
        case .ext(let wanted):
            return !entry.isDirectory
                && (entry.name as NSString).pathExtension.lowercased() == wanted
        case .kind(let kind):
            switch kind {
            case .folder: return entry.isDirectory
            case .file: return !entry.isDirectory
            default:
                return !entry.isDirectory
                    && kind.extensions.contains((entry.name as NSString).pathExtension.lowercased())
            }
        case .size(let op, let bytes):
            switch op {
            case .lt: return entry.size < bytes
            case .le: return entry.size <= bytes
            case .gt: return entry.size > bytes
            case .ge: return entry.size >= bytes
            case .eq: return entry.size == bytes
            }
        }
    }
}
