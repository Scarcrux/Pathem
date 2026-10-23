#if DEBUG
import AppKit
import PathemEngine

@MainActor
private final class SortingMetadataGate {
    private struct Pending {
        let entries: [FileEntry]
        let generation: UInt64?
        let continuation: CheckedContinuation<[FileEntry], Never>
    }
    private var pending: [Pending] = []
    var count: Int { pending.count }
    var generations: Set<UInt64> { Set(pending.compactMap(\.generation)) }
    func read(_ entries: [FileEntry], generation: UInt64? = nil) async -> [FileEntry] {
        await withCheckedContinuation {
            pending.append(Pending(entries: entries, generation: generation, continuation: $0))
        }
    }
    func release(last: Bool = false, result: [FileEntry]? = nil) {
        guard !pending.isEmpty else { return }
        let request = last ? pending.removeLast() : pending.removeFirst()
        request.continuation.resume(returning: result ?? request.entries)
    }
}

@MainActor
private final class SortingMetadataContexts {
    var values: [(URL?, Bool)] = []
}

@MainActor
private final class SortingRemoteFixture: RemoteProvider {
    let entries: [FileEntry]
    private(set) var lists = 0
    init(_ entries: [FileEntry]) { self.entries = entries }
    func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        lists += 1
        return entries
    }
    func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws { throw RemoteError.unsupported("fixture") }
    func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws { throw RemoteError.unsupported("fixture") }
    func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws
    { throw RemoteError.unsupported("fixture") }
    func remove(_ connection: RemoteConnection, path: String, isDirectory: Bool, password: String)
        async throws
    { throw RemoteError.unsupported("fixture") }
    func rename(_ connection: RemoteConnection, from: String, to: String, password: String)
        async throws
    { throw RemoteError.unsupported("fixture") }
}

extension BrowserViewController {
    func checkSortGroupDelivery(
        root: URL, check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool
    ) {
        checkSortGroupMenus(check: check)
        guard let pane = leftTabs.activePane else {
            check("sortgroup-pane", false)
            return
        }
        let fm = FileManager.default
        let data = root.appendingPathComponent("data", isDirectory: true)
        let columnsRoot = root.appendingPathComponent("columns", isDirectory: true)
        let columnChild = columnsRoot.appendingPathComponent("child", isDirectory: true)
        let treeRoot = root.appendingPathComponent("tree", isDirectory: true)
        let treeChild = treeRoot.appendingPathComponent("folder", isDirectory: true)
        do {
            for folder in [data, columnChild, treeChild] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(repeating: 65, count: 200_000).write(
                    to: folder.appendingPathComponent("alpha.txt"))
                try Data([66]).write(to: folder.appendingPathComponent("zebra.bin"))
            }
            for index in 0..<60 {
                try Data().write(
                    to: columnChild.appendingPathComponent(String(format: "filler-%03d", index)))
            }
            try FileMetadata.setTags(["Zulu"], on: treeChild.appendingPathComponent("alpha.txt"))
            try FileMetadata.setTags(["Alpha"], on: treeChild.appendingPathComponent("zebra.bin"))
            try FileMetadata.setTags(
                ["Named Project"], on: data.appendingPathComponent("alpha.txt"))
        } catch {
            check("sortgroup-fixtures", false)
            return
        }
        setActiveSide(leftTabs, pane: pane)
        pane.navigate(to: data)
        pane.debugClickViewSwitcher(.list)
        pane.applySort(key: .name, ascending: true)
        pane.setGroupKey(.none)
        check(
            "sortgroup-local-fixture-listed",
            settle { pane.entries.map(\.name) == ["alpha.txt", "zebra.bin"] })
        let originalRemember = pane.rememberFormat
        var writes: [String] = []
        pane.rememberFormat = { url, format in
            writes.append(url.path)
            originalRemember?(url, format)
        }
        defer {
            pane.debugMetadataLoader = nil
            pane.debugRemoteProviderFactory = nil
            pane.rememberFormat = originalRemember
        }
        let now = Date()
        let old = now.addingTimeInterval(-20 * 86_400)
        let entries = [
            FileEntry(
                name: "alpha.txt", isDirectory: false, size: 200_000, modificationDate: now,
                creationDate: old, accessDate: old,
                viewMetadata: FileViewMetadata(
                    kind: "Z Kind", dateAdded: old, lastOpenedDate: now,
                    tagNames: ["Zulu"], applicationName: "App B")),
            FileEntry(
                name: "zebra.bin", isDirectory: false, size: 1, modificationDate: old,
                creationDate: now, accessDate: now,
                viewMetadata: FileViewMetadata(
                    kind: "A Kind", dateAdded: now, lastOpenedDate: old,
                    tagNames: ["Alpha"], applicationName: "App A")),
        ]
        let metadataContexts = SortingMetadataContexts()
        pane.debugMetadataLoader = { entries, directory, _, local in
            await MainActor.run { metadataContexts.values.append((directory, local)) }
            return entries
        }
        pane.showSmartResults(entries, title: "Sorting fixture")
        let asc: [(ViewFormat.SortKey, [String])] = [
            (.name, ["alpha.txt", "zebra.bin"]), (.kind, ["zebra.bin", "alpha.txt"]),
            (.dateAccessed, ["zebra.bin", "alpha.txt"]), (.dateAdded, ["alpha.txt", "zebra.bin"]),
            (.date, ["zebra.bin", "alpha.txt"]), (.dateCreated, ["alpha.txt", "zebra.bin"]),
            (.size, ["zebra.bin", "alpha.txt"]), (.tags, ["zebra.bin", "alpha.txt"]),
        ]
        for (key, expected) in asc {
            for ascending in [true, false] {
                pane.applySort(key: key, ascending: ascending)
                let wanted = ascending ? expected : Array(expected.reversed())
                check(
                    "sortgroup-smart-actual-order-\(key.rawValue)-\(ascending)",
                    settle { pane.entries.map(\.name) == wanted })
            }
        }
        pane.applySort(key: .name, ascending: true)
        pane.setGroupKey(.kind)
        check(
            "sortgroup-smart-real-headers",
            settle { (pane.keyView as? NSTableView)?.numberOfRows == 4 })
        pane.setGroupKey(.none)
        check(
            "sortgroup-smart-none-removes-headers",
            settle { (pane.keyView as? NSTableView)?.numberOfRows == 2 })
        if let table = pane.keyView as? NSTableView {
            for id in [
                "name", "kind", "dateAccessed", "dateAdded", "date", "dateCreated", "size", "tags",
            ] {
                check(
                    "sortgroup-header-sortable-\(id)",
                    table.tableColumn(withIdentifier: .init(id))?.sortDescriptorPrototype?.key == id
                )
            }
            table.sortDescriptors = [NSSortDescriptor(key: "tags", ascending: true)]
            check(
                "sortgroup-smart-real-header-delivery",
                settle {
                    pane.sortKey == .tags && pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"]
                })
        } else {
            check("sortgroup-smart-real-header-delivery", false)
        }
        check("sortgroup-smart-no-fallback-writes", writes.isEmpty)
        check(
            "sortgroup-smart-no-fallback-directory",
            !metadataContexts.values.isEmpty
                && metadataContexts.values.allSatisfy { $0.0 == nil && $0.1 })
        pane.applySort(key: .name, ascending: true)
        pane.setGroupKey(.kind)
        check(
            "sortgroup-search-metadata-entered", settle { pane.entries.first?.name == "alpha.txt" })
        let searchDeliveries = pane.debugMetadataDeliveries
        pane.showResults(Array(entries.reversed()))
        check(
            "sortgroup-ranked-search-preserves-relevance",
            settle {
                pane.debugMetadataDeliveries > searchDeliveries
                    && pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"]
            })
        pane.setGroupKey(.none)
        pane.showSmartResults(entries, title: "Sorting fixture")

        let gate = SortingMetadataGate()
        pane.debugMetadataLoader = { entries, _, _, _ in await gate.read(entries) }
        let terminals = pane.debugMetadataTerminals
        pane.applySort(key: .kind, ascending: true)
        check("sortgroup-old-metadata-entered", settle { gate.count == 1 })
        pane.applySort(key: .tags, ascending: true)
        check("sortgroup-new-metadata-entered", settle { gate.count == 2 })
        gate.release(last: true)
        check(
            "sortgroup-new-metadata-delivered",
            settle {
                pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"]
                    && pane.debugMetadataTerminals > terminals
            })
        let reversedKind = entries.map { entry -> FileEntry in
            var value = entry
            value.viewMetadata = FileViewMetadata(kind: entry.name)
            return value
        }
        gate.release(result: reversedKind)
        check(
            "sortgroup-old-metadata-terminal-rejected",
            settle { pane.debugMetadataTerminals >= terminals + 2 }
                && pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"] && pane.sortKey == .tags)
        let beforeNavigation = pane.debugMetadataTerminals
        pane.applySort(key: .kind, ascending: true)
        check("sortgroup-navigation-metadata-entered", settle { gate.count == 1 })
        pane.navigate(to: data)
        gate.release()
        check(
            "sortgroup-navigation-rejects-late-metadata",
            settle {
                pane.debugMetadataTerminals > beforeNavigation && pane.currentURL.path == data.path
                    && pane.entries.map(\.name) == ["alpha.txt", "zebra.bin"]
            })
        let closed = PaneController(start: data)
        let closeGate = SortingMetadataGate()
        closed.debugMetadataLoader = { entries, _, _, _ in await closeGate.read(entries) }
        closed.showSmartResults(entries, title: "Closed fixture")
        closed.applySort(key: .kind, ascending: true)
        check("sortgroup-teardown-metadata-entered", settle { closeGate.count == 1 })
        let closedDeliveries = closed.debugMetadataDeliveries
        closed.teardown()
        closeGate.release()
        check(
            "sortgroup-teardown-rejects-late-metadata",
            settle { closed.debugMetadataTerminals > 0 }
                && closed.debugMetadataDeliveries == closedDeliveries)

        let provider = SortingRemoteFixture(entries)
        pane.debugMetadataLoader = { entries, _, _, _ in entries }
        pane.showSmartResults(entries, title: "Before remote fixture")
        pane.applySort(key: .kind, ascending: true)
        check(
            "sortgroup-before-remote-kind-ready", settle { pane.entries.first?.name == "zebra.bin" }
        )
        let remoteGate = SortingMetadataGate()
        pane.debugMetadataLoader = { entries, _, _, _ in await remoteGate.read(entries) }
        pane.debugRemoteProviderFactory = { _ in provider }
        let remoteTerminals = pane.debugMetadataTerminals
        let staleSmartRequest = pane.beginContentRequest()
        pane.openRemote(
            RemoteConnection(name: "Fixture", proto: .sftp, host: "fixture.invalid"), password: "")
        check(
            "sortgroup-remote-invalidates-old-smart-request",
            !pane.isContentRequestCurrent(staleSmartRequest))
        check(
            "sortgroup-remote-initial-metadata-entered",
            settle { remoteGate.count == 1 && provider.lists == 1 })
        pane.applySort(key: .size, ascending: true)
        check(
            "sortgroup-remote-pending-sort-retains-provider-rows",
            settle {
                pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"]
                    && !pane.isShowingSmartResults
            })
        remoteGate.release()
        check(
            "sortgroup-remote-old-initial-metadata-rejected",
            settle {
                pane.debugMetadataTerminals > remoteTerminals
            } && pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"] && provider.lists == 1)
        metadataContexts.values = []
        pane.debugMetadataLoader = { entries, directory, _, local in
            await MainActor.run { metadataContexts.values.append((directory, local)) }
            return entries
        }
        check(
            "sortgroup-remote-fixture-delivered",
            settle { pane.isRemote && pane.entries.count == 2 && provider.lists == 1 })
        pane.setGroupKey(.kind)
        pane.applySort(key: .size, ascending: true)
        check(
            "sortgroup-remote-group-sort-delivery",
            settle {
                pane.entries.map(\.name) == ["zebra.bin", "alpha.txt"]
                    && (pane.keyView as? NSTableView)?.numberOfRows == 4
            })
        check("sortgroup-remote-no-refetch-or-local-writes", provider.lists == 1 && writes.isEmpty)
        check(
            "sortgroup-remote-no-local-metadata",
            !metadataContexts.values.isEmpty
                && metadataContexts.values.allSatisfy { $0.0 == nil && !$0.1 })
        pane.debugMetadataLoader = nil
        pane.closeRemote()
        check(
            "sortgroup-local-return-delivered", settle { !pane.isRemote && pane.entries.count == 2 }
        )
        pane.applySort(key: .kind, ascending: true)
        check(
            "sortgroup-local-real-metadata-persisted",
            settle { pane.entries.allSatisfy { $0.viewMetadata?.kind != nil } }
                && writes.last == data.path)
        let metadataList = FileListController()
        var columnOptions = FolderViewOptions()
        columnOptions.columns = ["name", "tags", "dateAccessed"]
        columnOptions.showIconPreviews = false
        metadataList.directoryURL = data
        metadataList.setViewOptions(columnOptions)
        metadataList.setEntries(pane.entries, preserveState: false)
        check(
            "sortgroup-kind-sort-keeps-visible-tags",
            settle {
                metadataList.debugColumnText("tags", entryName: "alpha.txt") == "Named Project"
            })
        check(
            "sortgroup-basic-tags-delivered",
            FileColumns.gather(data.appendingPathComponent("alpha.txt"), [.finder]).tags
                == "Named Project")
        metadataList.allowsLocalMetadata = false
        metadataList.directoryURL = nil
        let deviceEntry = FileEntry(contentsOf: data.appendingPathComponent("alpha.txt"))
        metadataList.setEntries([deviceEntry], preserveState: false)
        let hostRequests = metadataList.debugExtendedReadRequests
        _ = metadataList.debugColumnText("dateAccessed", entryName: "alpha.txt")
        _ = metadataList.debugColumnText("tags", entryName: "alpha.txt")
        check(
            "sortgroup-provider-absolute-path-denies-host-reads",
            metadataList.debugExtendedReadRequests == hostRequests
                && metadataList.debugPendingExtendedReadCount == 0
                && metadataList.debugExtendedCacheCount == 0)

        pane.setGroupKey(.none)
        pane.reveal(data.appendingPathComponent("zebra.bin"))
        check(
            "sortgroup-explicit-reveal-survives-navigation",
            settle {
                pane.currentURL.path == data.path
                    && pane.selectedEntries.map(\.name) == ["zebra.bin"]
                    && pane.selectionRectInWindow != nil
            })
        pane.navigate(to: columnsRoot)
        pane.debugClickViewSwitcher(.column)
        pane.applySort(key: .size, ascending: true)
        check("sortgroup-column-root", settle { pane.entries.map(\.name) == ["child"] })
        pane.debugColumnDrill(row: 0)
        if let outline = pane.keyView as? NSTableView,
            let columns = outline.dataSource as? ColumnBrowserController
        {
            check(
                "sortgroup-column-child-ready",
                settle {
                    columns.debugColumnNames(1).count == 62 && !columns.debugHasPendingColumnLoad
                })
            check(
                "sortgroup-column-child-size-order",
                columns.debugColumnNames(1).filter { ["alpha.txt", "zebra.bin"].contains($0) } == [
                    "zebra.bin", "alpha.txt",
                ])
            if let index = columns.debugColumnNames(1).firstIndex(of: "zebra.bin") {
                pane.debugColumnDrill(row: index, column: 1)
            }
            columns.debugSetColumnOffset(NSPoint(x: 0, y: 160), inColumn: 1)
            let key = pane.keyView
            let offset = columns.debugColumnOffset(1)
            let completed = pane.debugListingCompletions
            pane.applySort(key: .size, ascending: false)
            check(
                "sortgroup-column-sort-refresh-completed",
                settle {
                    pane.debugListingCompletions > completed && !columns.isRefreshingDrilledColumns
                        && columns.debugColumnNames(1).first == "alpha.txt"
                })
            check(
                "sortgroup-column-sort-preserves-owner-selection-scroll",
                pane.currentURL.path == columnChild.path && pane.keyView === key
                    && pane.selectedEntries.map(\.name) == ["zebra.bin"]
                    && columns.debugColumnOffset(1) == offset)
        } else {
            check("sortgroup-column-controller", false)
        }
        pane.navigate(to: treeRoot)
        pane.debugClickViewSwitcher(.tree)
        pane.applySort(key: .size, ascending: false)
        if let outline = pane.keyView as? NSOutlineView,
            let tree = outline.dataSource as? TreeOutlineController
        {
            check("sortgroup-tree-root", settle { pane.debugHasEntry("folder") })
            let childGate = SortingMetadataGate()
            tree.debugBeforeTreeDelivery = { _, loaded in
                if !loaded { _ = await childGate.read([]) }
            }
            tree.debugExpand(names: ["folder"])
            check("sortgroup-tree-lazy-delivery-entered", settle { childGate.count == 1 })
            tree.debugCollapse(names: ["folder"])
            childGate.release()
            check(
                "sortgroup-tree-child-size-descending-order",
                settle {
                    tree.debugChildren(ofFolder: "folder")?.map(\.name) == [
                        "alpha.txt", "zebra.bin",
                    ] && tree.debugPendingChildLoads == 0
                })
            check(
                "sortgroup-tree-late-delivery-does-not-reexpand",
                !tree.debugTreeExpandedPaths.contains(treeChild.path))
            tree.debugBeforeTreeDelivery = nil
            tree.debugExpand(names: ["folder"])
            tree.debugSelectTreePath(treeChild.appendingPathComponent("zebra.bin").path)
            let selected = tree.debugTreeSelectedPaths
            let editGate = SortingMetadataGate()
            tree.debugBeforeTreeDeliveryWithGeneration = { _, loaded, generation in
                if loaded { _ = await editGate.read([], generation: generation) }
            }
            let treeListing = pane.debugListingCompletions
            pane.applySort(key: .tags, ascending: true)
            check(
                "sortgroup-tree-resort-delivery-entered",
                settle {
                    editGate.generations.contains(tree.debugTreeWorkGeneration)
                        && pane.debugListingCompletions > treeListing
                })
            check("sortgroup-tree-inline-edit-started", tree.beginInlineRename())
            while editGate.count > 0 { editGate.release() }
            check(
                "sortgroup-tree-resort-defers-for-editor",
                settle { tree.debugDeferredTreeDeliveries > 0 } && tree.isInlineEditing)
            tree.cancelInlineEdit()
            tree.debugBeforeTreeDeliveryWithGeneration = nil
            check(
                "sortgroup-tree-loaded-children-metadata-sort",
                settle {
                    tree.debugPendingChildLoads == 0
                        && tree.debugChildren(ofFolder: "folder")?.map(\.name) == [
                            "zebra.bin", "alpha.txt",
                        ]
                        && tree.debugChildren(ofFolder: "folder")?.first?.viewMetadata?.tagNames
                            == ["Alpha"]
                })
            check(
                "sortgroup-tree-sort-preserves-expansion-selection",
                tree.debugTreeExpandedPaths.contains(treeChild.path)
                    && tree.debugTreeSelectedPaths == selected)
            tree.debugCollapse(names: ["folder"])
            check(
                "sortgroup-tree-user-collapse-retained",
                settle { tree.debugPendingChildLoads == 0 }
                    && !tree.debugTreeExpandedPaths.contains(treeChild.path))
            let closeTreeGate = SortingMetadataGate()
            tree.debugBeforeTreeDelivery = { _, _ in _ = await closeTreeGate.read([]) }
            tree.setSortFormat(ViewFormat(sortKey: .tags, ascending: false))
            check("sortgroup-tree-close-work-entered", settle { closeTreeGate.count > 0 })
            let beforeClose = tree.debugTreeDeliveryCount
            let beforeTerminal = tree.debugTreeDeliveryTerminals
            pane.teardown()
            while closeTreeGate.count > 0 { closeTreeGate.release() }
            check(
                "sortgroup-tree-close-rejects-late-delivery",
                settle {
                    tree.debugTreeDeliveryTerminals > beforeTerminal
                } && tree.debugTreeDeliveryCount == beforeClose)
        } else {
            check("sortgroup-tree-controller", false)
        }
    }
}
#endif
