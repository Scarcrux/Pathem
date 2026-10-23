#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// The screenshot establishes menu choices, not Finder's private bucketing algorithm.
    /// These injected values discriminate date/tag/application sources without touching files.
    func checkSortGroupMenus(check: (String, Bool) -> Void) {
        let sortChoices: [(String, String, String, String)] = [
            ("name", "view.sortName", "list.columnName", "Name"),
            ("kind", "view.sortKind", "list.columnKind", "Kind"),
            (
                "dateAccessed", "view.sortDateAccessed", "list.columnDateAccessed",
                "Date Last Opened"
            ),
            ("dateAdded", "view.sortDateAdded", "list.columnDateAdded", "Date Added"),
            ("date", "view.sortDate", "list.columnDate", "Date Modified"),
            ("dateCreated", "view.sortDateCreated", "list.columnDateCreated", "Date Created"),
            ("size", "view.sortSize", "list.columnSize", "Size"),
            ("tags", "view.sortTags", "list.columnTags", "Tags"),
        ]
        let groupChoices: [(String, String, String, String)] = [
            ("none", "view.arrangeNone", "bvc.cmd.arrangeNone", "None"),
            ("name", "view.arrangeName", "list.columnName", "Name"),
            ("kind", "view.arrangeKind", "list.columnKind", "Kind"),
            ("application", "view.arrangeApplication", "viewchoice.application", "Application"),
            (
                "dateAccessed", "view.arrangeDateAccessed", "list.columnDateAccessed",
                "Date Last Opened"
            ),
            ("dateAdded", "view.arrangeDateAdded", "list.columnDateAdded", "Date Added"),
            ("dateModified", "view.arrangeDate", "list.columnDate", "Date Modified"),
            ("dateCreated", "view.arrangeDateCreated", "list.columnDateCreated", "Date Created"),
            ("size", "view.arrangeSize", "list.columnSize", "Size"),
            ("tag", "view.arrangeTag", "list.columnTags", "Tags"),
        ]
        var fixtureOptions = FolderViewOptions()
        fixtureOptions.showIconPreviews = false
        fixtureOptions.columns = ["name"]
        let options = ViewOptionsController(
            format: .default, effective: fixtureOptions, folderName: "Fixture")
        check(
            "sort-screenshot-raw-order",
            ViewFormat.SortKey.allCases.map(\.rawValue) == sortChoices.map(\.0))
        check(
            "group-screenshot-raw-order",
            ViewFormat.GroupKey.allCases.map(\.rawValue) == groupChoices.map(\.0))
        check(
            "view-options-eight-sort-labels",
            options.sort.itemTitles == sortChoices.map { L($0.2, $0.3) })
        check(
            "view-options-ten-group-labels",
            options.group.itemTitles == groupChoices.map { L($0.2, $0.3) })

        func menuItem(_ id: String, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.representedObject as? String == id { return item }
                if let child = menuItem(id, in: item.submenu) { return child }
            }
            return nil
        }
        for (index, choice) in sortChoices.enumerated() {
            options.sort.selectItem(at: index)
            check(
                "view-options-sort-roundtrip-\(choice.0)",
                options.format.sortKey.rawValue == choice.0)
            check(
                "main-menu-sort-label-\(choice.0)",
                menuItem(choice.1, in: NSApp.mainMenu)?.title == L(choice.2, choice.3))
        }
        for (index, choice) in groupChoices.enumerated() {
            options.group.selectItem(at: index)
            check(
                "view-options-group-roundtrip-\(choice.0)",
                options.format.groupKey.rawValue == choice.0)
            check(
                "main-menu-group-label-\(choice.0)",
                menuItem(choice.1, in: NSApp.mainMenu)?.title == L(choice.2, choice.3))
        }

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now).addingTimeInterval(60)
        let earlier =
            calendar.date(byAdding: .day, value: -60, to: today)
            ?? today.addingTimeInterval(-5_184_000)
        let entries = [
            FileEntry(
                name: "alpha.txt", isDirectory: false, size: 1, modificationDate: today,
                creationDate: earlier, accessDate: earlier,
                viewMetadata: FileViewMetadata(
                    kind: "Alpha Type", dateAdded: today, lastOpenedDate: today,
                    tagNames: ["Project A"], applicationName: "Editor A")),
            FileEntry(
                name: "zebra.txt", isDirectory: false, size: 2_000_000, modificationDate: earlier,
                creationDate: today, accessDate: today,
                viewMetadata: FileViewMetadata(
                    kind: "Zebra Type", dateAdded: earlier, lastOpenedDate: earlier,
                    tagNames: ["Project B"], applicationName: "Editor B")),
        ]
        func grouped(
            _ input: [FileEntry], _ key: ViewFormat.GroupKey,
            colors: (FileEntry) -> [FileTag.Color] = { _ in [] }
        ) -> [(String, [Int])] {
            var result: [(String, [Int])] = []
            for row in FileGrouping.rows(input, by: key, now: now, tagColors: colors) {
                switch row {
                case .header(let title): result.append((title, []))
                case .item(let index):
                    if !result.isEmpty { result[result.count - 1].1.append(index) }
                }
            }
            return result
        }
        let todayTitle = L("group.today", "Today")
        let earlierTitle = L("group.earlier", "Earlier")
        let expectedHeaders: [String: [String]] = [
            "name": ["A", "Z"], "kind": ["Alpha Type", "Zebra Type"],
            "application": ["Editor A", "Editor B"],
            "dateAccessed": [todayTitle, earlierTitle], "dateAdded": [todayTitle, earlierTitle],
            "dateModified": [todayTitle, earlierTitle], "dateCreated": [todayTitle, earlierTitle],
            "size": [
                L("group.sizeTiny", "Tiny (under 100 KB)"),
                L("group.sizeMedium", "Medium (1 to 100 MB)"),
            ],
            "tag": ["Project A", "Project B"],
        ]
        let list = FileListController()
        list.setViewOptions(fixtureOptions)
        list.setCalculateFolderSizes(false)
        list.setEntries(entries, preserveState: false)
        let icons = IconCollectionController(gallery: false)
        icons.setViewOptions(fixtureOptions)
        icons.setEntries(entries, preserveState: false)
        let collection = icons.debugKeyView as? NSCollectionView
        check("group-fixture-collection-delivered", collection != nil)
        for key in ViewFormat.GroupKey.allCases {
            let rows = FileGrouping.rows(entries, by: key, now: now)
            if key == .none {
                check("group-none-identity", rows == [.item(0), .item(1)])
            } else {
                let buckets = grouped(entries, key)
                check(
                    "group-headers-\(key.rawValue)",
                    buckets.map(\.0) == expectedHeaders[key.rawValue])
                let first = key == .dateCreated ? 1 : 0
                check(
                    "group-items-\(key.rawValue)",
                    buckets.count == 2 && buckets[0].1 == [first] && buckets[1].1 == [1 - first])
            }
            list.setGroupKey(key)
            check(
                "list-native-group-row-count-\(key.rawValue)",
                list.tableView.numberOfRows == (key == .none ? 2 : 4))
            list.select(name: "alpha.txt")
            check(
                "list-native-group-selection-\(key.rawValue)",
                list.selectedEntries.map(\.name) == ["alpha.txt"])
            icons.setGroupKey(key)
            if let collection {
                let sections = collection.numberOfSections
                check(
                    "icon-native-group-section-count-\(key.rawValue)",
                    sections == (key == .none ? 1 : 2))
                let itemCounts = (0..<sections).map { collection.numberOfItems(inSection: $0) }
                check(
                    "icon-native-group-item-count-\(key.rawValue)",
                    itemCounts == (key == .none ? [2] : [1, 1]))
            }
            icons.select(name: "alpha.txt")
            check(
                "icon-native-group-selection-\(key.rawValue)",
                icons.selectedEntries.map(\.name) == ["alpha.txt"])
        }

        let unicodeNames = [
            "Éclair.txt", "Echo.txt", "東京.txt", "Яблоко.txt", "３notes.txt", "😀.txt",
        ].map {
            FileEntry(name: $0, isDirectory: false, size: 0, modificationDate: nil)
        }
        let initials = grouped(unicodeNames, .name)
        check("group-name-folds-composed-accent", initials.first { $0.0 == "E" }?.1 == [0, 1])
        check(
            "group-name-keeps-non-latin-initials",
            initials.contains { $0.0 == "東" && $0.1 == [2] }
                && initials.contains { $0.0 == "Я" && $0.1 == [3] })
        check(
            "group-name-unicode-decimal-bucket",
            initials.first { $0.0 == L("group.nameNumbers", "0–9") }?.1 == [4])
        check(
            "group-name-symbol-bucket",
            initials.first { $0.0 == L("group.nameOther", "Other") }?.1 == [5])

        check(
            "group-named-tags-same-color-stay-distinct",
            grouped(entries, .tag, colors: { _ in [.red] }).map(\.0) == ["Project A", "Project B"])
        let unorderedTags = FileEntry(
            name: "tags.txt", isDirectory: false, size: 0, modificationDate: nil,
            viewMetadata: FileViewMetadata(tagNames: ["Zulu", "Alpha"]))
        check(
            "group-named-tags-deterministic-first",
            grouped([unorderedTags], .tag).map(\.0) == ["Alpha"])
        let emptyTags = FileEntry(
            name: "empty.txt", isDirectory: false, size: 0, modificationDate: nil,
            accessDate: today, viewMetadata: FileViewMetadata())
        check(
            "group-empty-tags-ignore-color-cache",
            grouped([emptyTags], .tag, colors: { _ in [.red] }).map(\.0) == [
                L("group.noTag", "No Tag")
            ])
        let legacy = FileEntry(
            name: "legacy.txt", isDirectory: false, size: 0, modificationDate: nil)
        check(
            "group-absent-metadata-retains-color-fallback",
            grouped([legacy], .tag, colors: { _ in [.red] }).map(\.0) == [FileTag.Color.red.label])
        check(
            "group-missing-last-opened-not-filesystem-access",
            grouped([emptyTags], .dateAccessed).map(\.0) == [L("group.dateUnknown", "Unknown Date")]
        )
        check(
            "group-missing-date-added-not-creation",
            grouped(
                [
                    FileEntry(
                        name: "created.txt", isDirectory: false, size: 0, modificationDate: nil,
                        creationDate: today)
                ], .dateAdded
            ).map(\.0) == [L("group.dateUnknown", "Unknown Date")])
        let folder = FileEntry(name: "Folder", isDirectory: true, size: 0, modificationDate: nil)
        check(
            "group-application-folder-and-unavailable-control",
            grouped([folder, legacy], .application).map(\.0) == [
                L("group.folders", "Folders"), L("group.noApplication", "No Application"),
            ])
    }
}
#endif
