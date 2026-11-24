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

    func entry(for category: FileIconCategory) -> (symbol: String, color: NSColor)? {
        symbols[category]
    }

    // Sets are identified by name (the symbol table has tuple values, which block synthesis).
    static func == (lhs: IconSet, rhs: IconSet) -> Bool { lhs.name == rhs.name }

    static let all: [IconSet] = [
        .system, .monochrome, .vivid, .blueprint,
        themed(.outline, color: .labelColor, outline: true),
        themed(.mint, color: .systemTeal),
        themed(.amber, color: .systemOrange),
        themed(.orchid, color: .systemPurple),
        themed(.twoTone, color: .systemBlue, detail: .systemTeal),
        themed(.ink, color: .labelColor),
    ]

    private static func themed(
        _ choice: ThemeStyles.FileIcons, color: NSColor, outline: Bool = false,
        detail: NSColor? = nil
    ) -> IconSet {
        let entries = FileIconCategory.allCases.map { category in
            let symbol = category.defaultSymbol
            let glyph = outline ? symbol.replacingOccurrences(of: ".fill", with: "") : symbol
            let tint =
                category == .generic || category == .document || category == .archive
                ? color : detail ?? color
            return (category, (glyph, tint))
        }
        return IconSet(
            name: choice.rawValue, isSystem: false,
            symbols: Dictionary(uniqueKeysWithValues: entries))
    }

    static let system = IconSet(name: "System", isSystem: true, symbols: [:])

    /// One clean monochrome symbol per category (secondary-label gray), for a calm, uniform look.
    static let monochrome: IconSet = {
        let gray = NSColor.secondaryLabelColor
        return IconSet(
            name: "Monochrome", isSystem: false,
            symbols: Dictionary(
                uniqueKeysWithValues: FileIconCategory.allCases.map {
                    ($0, ($0.defaultSymbol, gray))
                }))
    }()

    /// A distinct color per category, for a lively, easy-to-scan grid.
    static let vivid = IconSet(
        name: "Vivid", isSystem: false,
        symbols: [
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
        return IconSet(
            name: "Blueprint", isSystem: false,
            symbols: Dictionary(
                uniqueKeysWithValues: FileIconCategory.allCases.map {
                    ($0, ($0.defaultSymbol, indigo))
                }))
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
        func add(_ category: FileIconCategory, _ exts: [String]) {
            for e in exts { map[e] = category }
        }
        add(
            .image,
            [
                "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "svg",
                "raw",
            ])
        add(.video, ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv"])
        add(.audio, ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg", "opus"])
        add(.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg"])
        add(
            .code,
            [
                "swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp", "java", "sh", "json",
                "xml", "yml", "yaml", "toml", "html", "css",
            ])
        add(.pdf, ["pdf"])
        add(
            .document,
            [
                "txt", "md", "rtf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx",
                "numbers", "csv",
            ])
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
    private(set) var folderStyle: ThemeStyles.Folder = .system
    private var bundledIcons: [String: Data] = [:]
    private var cache: [FileIconCategory: NSImage] = [:]

    /// Adopt the set named `name` (from Preferences); returns true when it actually changed.
    @discardableResult
    func setCurrent(
        named name: String, folder: ThemeStyles.Folder = .system, bundled: [String: Data] = [:]
    ) -> Bool {
        let set = IconSet.all.first { $0.name == name } ?? .system
        guard set != current || folder != folderStyle || bundled != bundledIcons else {
            return false
        }
        current = set
        folderStyle = folder
        bundledIcons = bundled
        cache.removeAll()
        return true
    }

    /// The themed icon for an entry, or nil when the "System" set is active (use the OS icon).
    func icon(for entry: FileEntry) -> NSImage? {
        let category = FileIconCategory.of(entry)
        if let image = cache[category],
            category != .folder || folderStyle != .accent || bundledIcons[category.rawValue] != nil
        {
            return image
        }
        let image: NSImage?
        if let artwork = bundledIcons[category.rawValue], let bundled = NSImage(data: artwork) {
            image = bundled
        } else if category == .folder {
            image = folderIcon()
        } else {
            image = current.entry(for: category).map { Self.render($0.symbol, color: $0.color) }
        }
        cache[category] = image
        return image
    }

    /// Which QuickLook preview may replace this file's icon. A file the active theme draws
    /// (a file icon style other than System, or theme artwork for its category) keeps the
    /// themed icon unless it has real content to show; see `IconPreviewPolicy`.
    func previewKind(for entry: FileEntry) -> IconPreviewPolicy.Kind {
        IconPreviewPolicy.kind(forFileNamed: entry.name, themed: icon(for: entry) != nil)
    }

    private func folderIcon() -> NSImage? {
        switch folderStyle {
        case .system: return nil
        case .outline: return Self.render("folder", color: .labelColor)
        case .azure: return Self.render("folder.fill", color: .systemBlue)
        case .mint: return Self.render("folder.fill", color: .systemMint)
        case .amber: return Self.render("folder.fill", color: .systemOrange)
        case .plum: return Self.render("folder.fill", color: .systemPurple)
        case .coral: return Self.render("folder.fill", color: .systemPink)
        case .slate: return Self.render("folder.fill", color: .secondaryLabelColor)
        case .twoTone:
            let fill = Self.render("folder.fill", color: .systemTeal)
            let outline = Self.render("folder", color: .labelColor)
            return NSImage(size: fill.size, flipped: false) { rect in
                fill.draw(in: rect)
                outline.draw(in: rect)
                return true
            }
        case .accent: return Self.render("folder.fill", color: ThemeManager.shared.accent)
        }
    }

    /// Render an SF Symbol tinted with `color` at a size that scales cleanly to any cell.
    private static func render(_ symbol: String, color: NSColor, detail: NSColor? = nil) -> NSImage
    {
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color, detail ?? color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(
                systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
    }
}
