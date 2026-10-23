import PathemEngine

/// Shared labels and identifiers keep the menu bar, toolbar, context menu and View Options
/// in the same order as the persisted enum. Existing identifiers remain stable for keymaps.
extension ViewFormat.SortKey {
    var localizedTitle: String {
        switch self {
        case .name: return L("list.columnName", "Name")
        case .kind: return L("list.columnKind", "Kind")
        case .dateAccessed: return L("list.columnDateAccessed", "Date Last Opened")
        case .dateAdded: return L("list.columnDateAdded", "Date Added")
        case .date: return L("list.columnDate", "Date Modified")
        case .dateCreated: return L("list.columnDateCreated", "Date Created")
        case .size: return L("list.columnSize", "Size")
        case .tags: return L("list.columnTags", "Tags")
        }
    }

    var commandID: String {
        switch self {
        case .name: return "view.sortName"
        case .kind: return "view.sortKind"
        case .dateAccessed: return "view.sortDateAccessed"
        case .dateAdded: return "view.sortDateAdded"
        case .date: return "view.sortDate"
        case .dateCreated: return "view.sortDateCreated"
        case .size: return "view.sortSize"
        case .tags: return "view.sortTags"
        }
    }
}

extension ViewFormat.GroupKey {
    var localizedTitle: String {
        switch self {
        case .none: return L("bvc.cmd.arrangeNone", "None")
        case .name: return L("list.columnName", "Name")
        case .kind: return L("list.columnKind", "Kind")
        case .application: return L("viewchoice.application", "Application")
        case .dateAccessed: return L("list.columnDateAccessed", "Date Last Opened")
        case .dateAdded: return L("list.columnDateAdded", "Date Added")
        case .dateModified: return L("list.columnDate", "Date Modified")
        case .dateCreated: return L("list.columnDateCreated", "Date Created")
        case .size: return L("list.columnSize", "Size")
        case .tag: return L("list.columnTags", "Tags")
        }
    }

    var commandID: String {
        switch self {
        case .none: return "view.arrangeNone"
        case .name: return "view.arrangeName"
        case .kind: return "view.arrangeKind"
        case .application: return "view.arrangeApplication"
        case .dateAccessed: return "view.arrangeDateAccessed"
        case .dateAdded: return "view.arrangeDateAdded"
        case .dateModified: return "view.arrangeDate"
        case .dateCreated: return "view.arrangeDateCreated"
        case .size: return "view.arrangeSize"
        case .tag: return "view.arrangeTag"
        }
    }
}
