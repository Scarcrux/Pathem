import Foundation

/// User-defined named labels layered on the Finder-compatible tag system: a label
/// is just a colored tag with a meaningful name ("Important", "Work"), so applying
/// one writes an interoperable `_kMDItemUserTags` entry that Finder also shows. The
/// set is config-as-data (labels.json); Pathem owns the presentation (row tint),
/// the OS owns the tag string.
public struct FileLabel: Codable, Sendable, Equatable {
    public var name: String
    public var color: FileTag.Color

    public init(name: String, color: FileTag.Color) {
        self.name = name
        self.color = color
    }

    /// The tag this label writes.
    public var tag: FileTag { FileTag(name: name, color: color) }

    // Tolerant: an unknown color falls back to none rather than failing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? c.decode(FileTag.Color.self, forKey: .color)) ?? .none
    }

    private enum CodingKeys: String, CodingKey { case name, color }
}

public struct LabelSet: Codable, Sendable, Equatable {
    public var labels: [FileLabel]

    public init(labels: [FileLabel]) { self.labels = labels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decodeIfPresent([FileLabel].self, forKey: .labels) ?? []
    }

    private enum CodingKeys: String, CodingKey { case labels }

    /// A useful starter set of named labels (each maps to a Finder color), going
    /// beyond the bare color names.
    public static let `default` = LabelSet(labels: [
        FileLabel(name: "Important", color: .red),
        FileLabel(name: "Work", color: .blue),
        FileLabel(name: "Personal", color: .green),
        FileLabel(name: "Draft", color: .orange),
        FileLabel(name: "Review", color: .purple),
        FileLabel(name: "Hold", color: .yellow),
        FileLabel(name: "Archive", color: .gray),
    ])
}
