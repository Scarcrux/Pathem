import CoreFoundation
import Foundation

/// The versioned interchange format for Pathem appearance settings.
public enum ThemePackage {
    public static let maximumBytes = 16 * 1024
    private static let styleFields: Set<String> = ["folderStyle", "fileIconSet", "toolbarStyle"]
    private static let fields: Set<String> = [
        "schemaVersion", "name", "appearance", "accent", "background",
    ]

    public enum ValidationError: LocalizedError, Equatable {
        case tooLarge, invalidDocument, invalidName
        case unsupportedVersion(Int)
        case invalidColor(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "Theme packages must be 16 KiB or smaller."
            case .invalidDocument: return "Expected a UTF-8 JSON theme with the required fields."
            case .invalidName: return "A theme must have a name."
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
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw ValidationError.unsupportedVersion(schemaVersion)
        }
        let expectedFields = schemaVersion == 1 ? fields : fields.union(styleFields)
        guard Set(object.keys) == expectedFields,
            let name = object["name"] as? String,
            let mode = object["appearance"] as? String,
            let appearance = Preferences.Appearance(rawValue: mode)
        else { throw ValidationError.invalidDocument }
        var styles: ThemeStyles?
        if schemaVersion == 2 {
            guard let folder = (object["folderStyle"] as? String).flatMap(ThemeStyles.Folder.init),
                let files = (object["fileIconSet"] as? String).flatMap(ThemeStyles.FileIcons.init),
                let toolbar = (object["toolbarStyle"] as? String).flatMap(ThemeStyles.Toolbar.init)
            else { throw ValidationError.invalidDocument }
            styles = ThemeStyles(folder, files, toolbar)
        }
        return try ThemePreset(
            name: validatedName(name), appearance: appearance,
            accentHex: color(object["accent"], field: "accent"),
            backgroundHex: color(object["background"], field: "background"), styles: styles)
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
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge }
        return data
    }

    // Foundation accepts trailing commas. Skip quoted strings so theme names may contain ",}".
    private static func hasTrailingComma(_ json: String) -> Bool {
        let tokens = /"(?:[^"\\]|\\.)*"|,[\t\r\n ]*[}\]]/
        return json.matches(of: tokens).contains { $0.output.first == "," }
    }

    private static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.invalidName }
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
