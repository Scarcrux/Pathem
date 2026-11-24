/// Stable identifiers shared by preferences, packages, and appearance controls.
public struct ThemeStyles: Codable, Sendable, Equatable {
    public enum Folder: String, Codable, Sendable, CaseIterable {
        case system = "System"
        case outline = "Outline"
        case azure = "Azure"
        case mint = "Mint"
        case amber = "Amber"
        case plum = "Plum"
        case coral = "Coral"
        case slate = "Slate"
        case twoTone = "Two-Tone"
        case accent = "Accent"
    }

    public enum FileIcons: String, Codable, Sendable, CaseIterable {
        case system = "System"
        case monochrome = "Monochrome"
        case vivid = "Vivid"
        case blueprint = "Blueprint"
        case outline = "Outline"
        case mint = "Mint"
        case amber = "Amber"
        case orchid = "Orchid"
        case twoTone = "Two-Tone"
        case ink = "Ink"
    }

    public enum Toolbar: String, Codable, Sendable, CaseIterable {
        case system = "System"
        case fine = "Fine"
        case bold = "Bold"
        case heavy = "Heavy"
        case solid = "Solid"
        case rounded = "Rounded"
        case arrowheads = "Arrowheads"
        case circled = "Circled"
        case squared = "Squared"
        case compact = "Compact"
    }

    public var folder: Folder
    public var fileIcons: FileIcons
    public var toolbar: Toolbar

    public init(_ folder: Folder, _ fileIcons: FileIcons, _ toolbar: Toolbar) {
        self.folder = folder
        self.fileIcons = fileIcons
        self.toolbar = toolbar
    }

    public static let system = ThemeStyles(.system, .system, .system)
}
