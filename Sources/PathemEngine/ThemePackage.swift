import CoreFoundation
import Foundation

/// The versioned interchange format for Pathem appearance settings.
public enum ThemePackage {
    public static let maximumBytes = 384 * 1024
    private static let paletteLimit = 16 * 1024
    private static let styleFields: Set<String> = ["folderStyle", "fileIconSet", "toolbarStyle"]
    private static let fields: Set<String> = [
        "schemaVersion", "name", "appearance", "accent", "background",
    ]

    public enum ValidationError: LocalizedError, Equatable {
        case tooLarge, invalidDocument, invalidName, invalidArtwork
        case unsupportedVersion(Int)
        case invalidColor(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "Theme package exceeds the size limit for its format."
            case .invalidArtwork: return "Theme artwork must use small, single-frame PNG icons."
            case .invalidDocument: return "Expected a UTF-8 JSON theme with the required fields."
            case .invalidName: return "Enter a theme name of up to 160 UTF-8 bytes."
            case .unsupportedVersion(let version):
                return "Theme package version \(version) is unsupported."
            case .invalidColor(let field): return "The \(field) color must be #RRGGBB or null."
            }
        }
    }

    public static func decode(_ data: Data) throws -> ThemePreset {
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge }
        guard !data.contains(0), let json = String(data: data, encoding: .utf8),
            !hasTrailingComma(json),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let number = object["schemaVersion"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let schemaVersion = Int(number.stringValue)
        else { throw ValidationError.invalidDocument }
        guard (1...3).contains(schemaVersion) else {
            throw ValidationError.unsupportedVersion(schemaVersion)
        }
        if schemaVersion < 3, data.count > paletteLimit { throw ValidationError.tooLarge }
        var expectedFields = schemaVersion == 1 ? fields : fields.union(styleFields)
        if schemaVersion == 3 { expectedFields.insert("artwork") }
        guard Set(object.keys) == expectedFields,
            let name = object["name"] as? String,
            let mode = object["appearance"] as? String,
            let appearance = Preferences.Appearance(rawValue: mode)
        else { throw ValidationError.invalidDocument }
        var styles: ThemeStyles?
        if schemaVersion >= 2 {
            guard let folder = (object["folderStyle"] as? String).flatMap(ThemeStyles.Folder.init),
                let files = (object["fileIconSet"] as? String).flatMap(ThemeStyles.FileIcons.init),
                let toolbar = (object["toolbarStyle"] as? String).flatMap(ThemeStyles.Toolbar.init)
            else { throw ValidationError.invalidDocument }
            styles = ThemeStyles(folder, files, toolbar)
        }
        let artwork = try object["artwork"].map { value in
            try JSONDecoder().decode(
                ThemeArtwork.self,
                from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
        return try ThemePreset(
            name: validatedName(name), appearance: appearance,
            accentHex: color(object["accent"], field: "accent"),
            backgroundHex: color(object["background"], field: "background"), styles: styles,
            artwork: artwork)
    }

    public static func encode(_ preset: ThemePreset) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": preset.styles == nil ? 1 : 2,
            "name": try validatedName(preset.name),
            "appearance": preset.appearance.rawValue,
            "accent": exportColor(preset.accentHex),
            "background": exportColor(preset.backgroundHex),
        ]
        if let styles = preset.styles {
            object["folderStyle"] = styles.folder.rawValue
            object["fileIconSet"] = styles.fileIcons.rawValue
            object["toolbarStyle"] = styles.toolbar.rawValue
        }
        if let artwork = preset.artwork {
            let styles = preset.styles ?? .system
            object["schemaVersion"] = 3
            object["folderStyle"] = styles.folder.rawValue
            object["fileIconSet"] = styles.fileIcons.rawValue
            object["toolbarStyle"] = styles.toolbar.rawValue
            object["artwork"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(artwork))
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= (preset.artwork == nil ? paletteLimit : maximumBytes)
        else { throw ValidationError.tooLarge }
        return data
    }

    // Foundation accepts trailing commas. Skip quoted strings so theme names may contain ",}".
    private static func hasTrailingComma(_ json: String) -> Bool {
        let tokens = /"(?:[^"\\]|\\.)*"|,[\t\r\n ]*[}\]]/
        return json.matches(of: tokens).contains { $0.output.first == "," }
    }

    private static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...160).contains(trimmed.utf8.count),
            trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw ValidationError.invalidName }
        return trimmed
    }

    private static func color(_ value: Any?, field: String) throws -> String {
        if value is NSNull { return "" }
        guard let hex = value as? String, hex.utf8.count == 7, hex.hasPrefix("#"),
            hex.utf8.dropFirst().allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { throw ValidationError.invalidColor(field) }
        return hex.uppercased()
    }

    private static func exportColor(_ value: String) -> Any {
        guard let color = HexColor.parse(value) else { return NSNull() }
        return HexColor.format(r: color.r, g: color.g, b: color.b)
    }
}
