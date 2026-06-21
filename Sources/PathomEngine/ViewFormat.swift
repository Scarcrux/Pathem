import Foundation

/// How a folder is displayed: sort key and direction, whether hidden files show,
/// and whether folders sort first. Codable so it can be saved per folder and
/// shared (config-as-data, DESIGN.md section 10). Later this grows columns and a
/// view mode; the sort logic lives here so it is unit-testable.
public struct ViewFormat: Codable, Sendable, Equatable {
    public enum SortKey: String, Codable, Sendable, CaseIterable { case name, size, date }

    public var sortKey: SortKey
    public var ascending: Bool
    public var showHidden: Bool
    public var foldersFirst: Bool

    public init(
        sortKey: SortKey = .name, ascending: Bool = true,
        showHidden: Bool = false, foldersFirst: Bool = true
    ) {
        self.sortKey = sortKey
        self.ascending = ascending
        self.showHidden = showHidden
        self.foldersFirst = foldersFirst
    }

    public static let `default` = ViewFormat()

    /// Sort entries per this format. Folders-first (when set) is independent of
    /// the sort direction; ties fall back to a stable localized name compare.
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }

            let ordered: Bool
            switch sortKey {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                if cmp == .orderedSame { return false }
                ordered = cmp == .orderedAscending
            case .size:
                if a.size == b.size { return nameAscending(a, b) }
                ordered = a.size < b.size
            case .date:
                let da = a.modificationDate ?? .distantPast
                let db = b.modificationDate ?? .distantPast
                if da == db { return nameAscending(a, b) }
                ordered = da < db
            }
            return ascending ? ordered : !ordered
        }
    }

    private func nameAscending(_ a: FileEntry, _ b: FileEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
