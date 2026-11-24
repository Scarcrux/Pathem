import CoreFoundation
import Foundation

/// Translates color data from other applications into Pathem's appearance roles.
public enum ExternalThemeImport {
    public static let maximumBytes = 512 * 1024

    public struct TerminalPalette: Equatable, Sendable {
        public let name: String
        public let background: String?
        public let foreground: String?
        public let cursor: String?
        public let ansi: [String]?
    }

    public enum ImportError: LocalizedError, Equatable {
        case invalidPalette

        public var errorDescription: String? {
            "The file does not contain a supported color palette."
        }
    }

    public static func vscode(_ data: Data, name: String) throws -> ThemePreset {
        guard data.count <= maximumBytes, let source = String(data: data, encoding: .utf8)
        else { throw ImportError.invalidPalette }
        // Preserve quoted strings, including escaped quotes and URLs, inside JSONC.
        let json = source.replacing(/"(?:[^"\\]|\\.)*"|\/\/[^\r\n]*|\/\*[\s\S]*?\*\//) {
            $0.output.first == "\"" ? String($0.output) : " "
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let colors = root["colors"] as? [String: Any]
        else { throw ImportError.invalidPalette }
        let background = ["editor.background", "sideBar.background"]
            .lazy.compactMap { opaqueHex(colors[$0]) }.first
        let accent = ["focusBorder", "activityBarBadge.background", "button.background"]
            .lazy.compactMap { opaqueHex(colors[$0]) }.first
        guard background != nil || accent != nil else { throw ImportError.invalidPalette }
        let appearance: Preferences.Appearance
        switch root["type"] as? String {
        case "dark", "hcDark": appearance = .dark
        case "light", "hcLight": appearance = .light
        default: appearance = .system
        }
        return ThemePreset(
            name: name, appearance: appearance, accentHex: accent ?? "",
            backgroundHex: background ?? "")
    }

    public static func iterm(_ data: Data, name: String) throws -> TerminalPalette {
        guard data.count <= maximumBytes,
            let root = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { throw ImportError.invalidPalette }
        let background = components(root["Background Color"])
        let foreground = components(root["Foreground Color"])
        let cursor = components(root["Cursor Color"])
        let ansi = (0..<16).compactMap { components(root["Ansi \($0) Color"]) }
        guard background != nil || foreground != nil || cursor != nil || ansi.count == 16
        else { throw ImportError.invalidPalette }
        return TerminalPalette(
            name: name, background: background, foreground: foreground,
            cursor: cursor, ansi: ansi.count == 16 ? ansi : nil)
    }

    private static func opaqueHex(_ value: Any?) -> String? {
        guard let value = value as? String, value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())
        let digits: String
        switch hex.utf8.count {
        case 3: digits = hex.map { "\($0)\($0)" }.joined()
        case 4 where hex.last?.lowercased() == "f":
            digits = hex.dropLast().map { "\($0)\($0)" }.joined()
        case 6: digits = hex
        case 8 where hex.suffix(2).lowercased() == "ff": digits = String(hex.prefix(6))
        default: return nil
        }
        guard digits.utf8.count == 6,
            digits.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { return nil }
        return "#" + digits.uppercased()
    }

    private static func components(_ value: Any?) -> String? {
        guard let values = value as? [String: Any],
            values["Color Space"].map({ ["sRGB", "Calibrated"].contains($0 as? String ?? "") })
                ?? true
        else { return nil }
        let components = ["Red Component", "Green Component", "Blue Component"].compactMap {
            key -> Int? in
            guard let number = values[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                (0...1).contains(number.doubleValue)
            else { return nil }
            return Int((number.doubleValue * 255).rounded())
        }
        guard components.count == 3 else { return nil }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }
}
