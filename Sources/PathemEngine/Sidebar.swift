import Foundation

/// The user-customizable part of the sidebar, persisted as config-as-data
/// (sidebar.json): named groups of named, icon-bearing shortcuts to folders.
/// Reorder, rename, re-icon, and regroup are all pure mutations here so they are
/// unit-tested; the Cloud and Volumes sections are auto-detected elsewhere and
/// are not part of this model.
public struct Sidebar: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var icon: String  // SF Symbol name
        public var path: String  // target folder

        public init(id: UUID = UUID(), name: String, icon: String, path: String) {
            self.id = id
            self.name = name
            self.icon = icon
            self.path = path
        }
    }

    public struct Group: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var items: [Item]

        public init(id: UUID = UUID(), title: String, items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    public var groups: [Group]

    public init(groups: [Group]) { self.groups = groups }

    /// The seed for a fresh install: a Favorites group of the standard places.
    public static func makeDefault(home: URL) -> Sidebar {
        func place(_ name: String, _ icon: String, _ url: URL) -> Item {
            Item(name: name, icon: icon, path: url.path)
        }
        let favorites = Group(
            title: "Favorites",
            items: [
                place("Home", "house", home),
                place("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
                place("Documents", "doc", home.appendingPathComponent("Documents")),
                place("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
                place("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications")),
            ])
        return Sidebar(groups: [favorites])
    }

    // MARK: Lookup

    /// (group index, item index) for an item id.
    public func locate(_ itemID: UUID) -> (group: Int, item: Int)? {
        for (g, group) in groups.enumerated() {
            if let i = group.items.firstIndex(where: { $0.id == itemID }) { return (g, i) }
        }
        return nil
    }

    public func groupIndex(_ groupID: UUID) -> Int? {
        groups.firstIndex(where: { $0.id == groupID })
    }

    // MARK: Item mutations

    public mutating func addItem(_ item: Item, toGroup groupID: UUID) {
        guard let g = groupIndex(groupID) else { return }
        groups[g].items.append(item)
    }

    public mutating func removeItem(_ itemID: UUID) {
        guard let at = locate(itemID) else { return }
        groups[at.group].items.remove(at: at.item)
    }

    public mutating func renameItem(_ itemID: UUID, to name: String) {
        guard let at = locate(itemID) else { return }
        groups[at.group].items[at.item].name = name
    }

    public mutating func setIcon(_ itemID: UUID, to icon: String) {
        guard let at = locate(itemID) else { return }
        groups[at.group].items[at.item].icon = icon
    }

    /// Move an item to `targetGroup` at `targetIndex` (clamped). Works within or
    /// across groups; the index refers to the destination group after removal.
    public mutating func moveItem(_ itemID: UUID, toGroup targetGroup: UUID, at targetIndex: Int) {
        guard let from = locate(itemID), let g = groupIndex(targetGroup) else { return }
        let item = groups[from.group].items.remove(at: from.item)
        var index = targetIndex
        // Removing from the same group before the insertion point shifts it left.
        if from.group == g, from.item < targetIndex { index -= 1 }
        index = min(max(index, 0), groups[g].items.count)
        groups[g].items.insert(item, at: index)
    }

    // MARK: Group mutations

    @discardableResult
    public mutating func addGroup(title: String) -> UUID {
        let group = Group(title: title, items: [])
        groups.append(group)
        return group.id
    }

    public mutating func removeGroup(_ groupID: UUID) {
        groups.removeAll { $0.id == groupID }
    }

    public mutating func renameGroup(_ groupID: UUID, to title: String) {
        guard let g = groupIndex(groupID) else { return }
        groups[g].title = title
    }

    public mutating func moveGroup(_ groupID: UUID, to targetIndex: Int) {
        guard let from = groupIndex(groupID) else { return }
        let group = groups.remove(at: from)
        var index = targetIndex
        if from < targetIndex { index -= 1 }
        index = min(max(index, 0), groups.count)
        groups.insert(group, at: index)
    }
}
