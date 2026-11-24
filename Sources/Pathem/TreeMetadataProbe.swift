#if DEBUG
import AppKit
import PathemEngine

/// Offscreen regression for a content-only edit below an expanded Tree node.
@MainActor
enum TreeMetadataProbe {
    static func run() throws -> Bool {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-tree-stat-\(UUID())")
        let folder = root.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let child = folder.appendingPathComponent("child.txt")
        try Data("old".utf8).write(to: child)
        let before = FileEntry(contentsOf: folder)
        let tree = TreeOutlineController()
        defer { tree.cancelPendingWork() }
        tree.directoryURL = root
        tree.setEntries([before], preserveState: false)
        tree.debugExpand(names: ["folder"])
        guard settle({ tree.debugChildren(ofFolder: "folder")?.first?.size == 3 }) else {
            print("TREE STAT: loading control did not deliver")
            return false
        }
        let selected = child.standardizedFileURL.path
        tree.debugSelectTreePath(selected)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("updated bytes".utf8).write(to: child, options: [])
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: child.path)
        let after = FileEntry(contentsOf: folder)
        guard after.modificationDate == before.modificationDate else {
            print("TREE STAT: parent changed, invalid fixture")
            return false
        }

        tree.setEntries([after], preserveState: true)
        guard settle({ tree.debugPendingChildLoads == 0 }),
            let actual = tree.debugChildren(ofFolder: "folder")?.first
        else { return false }
        let expected = FileEntry(contentsOf: child)
        let keptState =
            !tree.debugTreeExpandedPaths.isEmpty && tree.debugTreeSelectedPaths == [selected]
        print(
            "TREE STAT: size=\(actual.size)/\(expected.size) dateMatches=\(actual.modificationDate == expected.modificationDate) state=\(keptState)"
        )
        return actual.size == expected.size && actual.modificationDate == expected.modificationDate
            && keptState
    }

    private static func settle(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
#endif
