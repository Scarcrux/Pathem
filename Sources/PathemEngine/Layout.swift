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

    public init(name: String, leftPath: String, rightPath: String, dividerFraction: Double) {
        self.name = name
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.dividerFraction = dividerFraction
    }
}

/// The saved layouts, persisted as config-as-data (DESIGN.md section 10).
public struct Layouts: Codable, Sendable {
    public var layouts: [Layout]

    public init(layouts: [Layout] = []) { self.layouts = layouts }

    /// Save by name, replacing any existing layout with the same name.
    public mutating func save(_ layout: Layout) {
        layouts.removeAll { $0.name == layout.name }
        layouts.append(layout)
    }

    public func named(_ name: String) -> Layout? { layouts.first { $0.name == name } }

    public var names: [String] { layouts.map(\.name) }
}
