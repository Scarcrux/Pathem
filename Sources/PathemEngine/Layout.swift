import Foundation

/// A saved workspace arrangement: where each pane points and how the split is
/// divided. View formats are not stored here; they live per folder in
/// FolderFormats and reapply automatically when a pane navigates, so a layout
/// stays small and a folder looks the same however you arrive at it.
public struct Layout: Codable, Sendable, Equatable {
    public var name: String
    public var leftPath: String
    public var rightPath: String
    public var dividerFraction: Double
    /// The panes are stacked top and bottom (left pane on top). Layouts saved before this
    /// field existed decode as side by side.
    public var stackedPanes: Bool

    public init(
        name: String, leftPath: String, rightPath: String, dividerFraction: Double,
        stackedPanes: Bool = false
    ) {
        self.stackedPanes = stackedPanes
        self.name = name
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.dividerFraction = dividerFraction
    }

    // Tolerant: an older/partial layouts.json loads with defaults rather than
    // failing the whole [Layout] array (which would drop every saved layout).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        leftPath = try c.decodeIfPresent(String.self, forKey: .leftPath) ?? ""
        rightPath = try c.decodeIfPresent(String.self, forKey: .rightPath) ?? ""
        dividerFraction = try c.decodeIfPresent(Double.self, forKey: .dividerFraction) ?? 0.5
        stackedPanes = try c.decodeIfPresent(Bool.self, forKey: .stackedPanes) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case name, leftPath, rightPath, dividerFraction, stackedPanes
    }
}

/// The saved layouts, persisted as config-as-data (DESIGN.md section 10).
public struct Layouts: Codable, Sendable {
    public var layouts: [Layout]

    public init(layouts: [Layout] = []) { self.layouts = layouts }

    // Tolerant: a missing/older key loads as empty instead of failing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layouts = try c.decodeIfPresent([Layout].self, forKey: .layouts) ?? []
    }

    private enum CodingKeys: String, CodingKey { case layouts }

    /// Save by name, replacing any existing layout with the same name.
    public mutating func save(_ layout: Layout) {
        layouts.removeAll { $0.name == layout.name }
        layouts.append(layout)
    }

    public func named(_ name: String) -> Layout? { layouts.first { $0.name == name } }

    public var names: [String] { layouts.map(\.name) }
}
