import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// A swappable icon theme. "System" (the default) uses the icons macOS assigns; the others render
/// a themed SF Symbol per file category, so a whole icon set ships as a small table of symbol +
/// color instead of bundled image files. The active set overrides the `NSWorkspace` lookup in the
/// file views; anything it doesn't cover falls back to the system icon.
struct IconSet: Equatable {
    let name: String
    /// True for "System": no overrides, use the OS icons.
    let isSystem: Bool
    /// Per-category SF Symbol + color; a missing category falls back to the system icon.
    let symbols: [FileIconCategory: (symbol: String, color: NSColor)]

    func entry(for category: FileIconCategory) -> (symbol: String, color: NSColor)? { symbols[category] }

    // Sets are identified by name (the symbol table has tuple values, which block synthesis).
    static func == (lhs: IconSet, rhs: IconSet) -> Bool { lhs.name == rhs.name }

    static let all: [IconSet] = [.system, .monochrome, .vivid, .blueprint]

    static let system = IconSet(name: "System", isSystem: true, symbols: [:])

    /// One clean monochrome symbol per category (secondary-label gray), for a calm, uniform look.
    static let monochrome: IconSet = {
        let gray = NSColor.secondaryLabelColor
        return IconSet(name: "Monochrome", isSystem: false, symbols: Dictionary(
            uniqueKeysWithValues: FileIconCategory.allCases.map { ($0, ($0.defaultSymbol, gray)) }))
    }()

    /// A distinct color per category, for a lively, easy-to-scan grid.
    static let vivid = IconSet(name: "Vivid", isSystem: false, symbols: [
        .folder: ("folder.fill", .systemBlue),
        .image: ("photo.fill", .systemGreen),
        .video: ("film.fill", .systemPurple),
        .audio: ("music.note", .systemPink),
        .archive: ("archivebox.fill", .systemBrown),
        .code: ("chevron.left.forwardslash.chevron.right", .systemTeal),
        .pdf: ("doc.richtext.fill", .systemRed),
        .document: ("doc.fill", .systemGray),
        .app: ("app.fill", .systemOrange),
        .generic: ("doc", .systemGray),
    ])

    /// A single-hue (indigo) set, all filled symbols, for a cohesive "blueprint" feel.
    static let blueprint: IconSet = {
        let indigo = NSColor.systemIndigo
        return IconSet(name: "Blueprint", isSystem: false, symbols: Dictionary(
            uniqueKeysWithValues: FileIconCategory.allCases.map { ($0, ($0.defaultSymbol, indigo)) }))
    }()
}

/// Broad file kinds an icon set themes.
enum FileIconCategory: String, CaseIterable {
    case folder, image, video, audio, archive, code, pdf, document, app, generic

    var defaultSymbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .archive: return "archivebox.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pdf: return "doc.richtext.fill"
        case .document: return "doc.fill"
        case .app: return "app.fill"
        case .generic: return "doc.fill"
        }
    }

    private static let byExtension: [String: FileIconCategory] = {
        var map: [String: FileIconCategory] = [:]
        func add(_ category: FileIconCategory, _ exts: [String]) { for e in exts { map[e] = category } }
        add(.image, ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "svg", "raw"])
        add(.video, ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv"])
        add(.audio, ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg", "opus"])
        add(.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg"])
        add(.code, ["swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp", "java", "sh", "json", "xml", "yml", "yaml", "toml", "html", "css"])
        add(.pdf, ["pdf"])
        add(.document, ["txt", "md", "rtf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx", "numbers", "csv"])
        add(.app, ["app"])
        return map
    }()

    /// The category for a file entry (folders first, then by extension, else generic).
    static func of(_ entry: FileEntry) -> FileIconCategory {
        if entry.isDirectory { return .folder }
        return byExtension[(entry.name as NSString).pathExtension.lowercased()] ?? .generic
    }
}

/// Resolves the active icon set and renders (and caches) its symbol icons. macOS 15+.
@MainActor
final class IconSetManager {
    static let shared = IconSetManager()

    private(set) var current: IconSet = .system
    private var cache: [String: NSImage] = [:]

    /// Adopt the set named `name` (from Preferences); returns true when it actually changed.
    @discardableResult
    func setCurrent(named name: String) -> Bool {
        let set = IconSet.all.first { $0.name == name } ?? .system
        guard set != current else { return false }
        current = set
        cache.removeAll()
        return true
    }

    /// The themed icon for an entry, or nil when the "System" set is active (use the OS icon).
    func icon(for entry: FileEntry) -> NSImage? {
        guard !current.isSystem else { return nil }
        let category = FileIconCategory.of(entry)
        let key = "\(current.name)|\(category.rawValue)"
        if let hit = cache[key] { return hit }
        guard let spec = current.entry(for: category) else { return nil }
        let image = Self.render(spec.symbol, color: spec.color)
        cache[key] = image
        return image
    }

    /// Render an SF Symbol tinted with `color` at a size that scales cleanly to any cell.
    private static func render(_ symbol: String, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
    }
}
