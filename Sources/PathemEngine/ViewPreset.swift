import Foundation

/// A named, reusable view configuration: a view mode + sort + grouping + hidden/folders-first,
/// captured from a folder and applicable to any other ("Photos = big icons by date", "Code = list
/// by name with git"). The precursor to plugin-defined custom views; built on the existing
/// `ViewFormat`, persisted as view-presets.json. Foundation-only.
public struct ViewPreset: Codable, Sendable, Equatable {
    public var name: String
    public var format: ViewFormat

    public init(name: String, format: ViewFormat) {
        self.name = name
        self.format = format
    }
}

public struct ViewPresets: Codable, Sendable, Equatable {
    public var presets: [ViewPreset]

    public init(presets: [ViewPreset] = []) { self.presets = presets }

    public static let `default` = ViewPresets()

    /// Tolerant decode so an older/newer file never resets the user's presets.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = (try? c.decodeIfPresent([ViewPreset].self, forKey: .presets)) ?? []
    }

    /// Add or replace by name (names are the identity).
    public mutating func save(_ preset: ViewPreset) {
        presets.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func remove(named name: String) {
        presets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
