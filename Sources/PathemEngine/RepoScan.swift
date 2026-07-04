import Foundation

/// The git-aware reclaim split: inside a git repository, a folder's contents fall into three
/// buckets. Tracked files are already backed up by git (if pushed), so leave them. Untracked
/// files that are regenerable (build output, caches, dependency trees) are safe to clean.
/// Untracked files that are NOT derivable (a dataset, a checkpoint, notes) are precious and
/// worth backing up, since git isn't protecting them. Pure Foundation (shelling out to git,
/// out-of-process), unit-tested against a real temp repo.
public enum RepoScan {
    public enum Disposition: String, Sendable, Equatable { case tracked, regenerable, precious }

    public struct Item: Sendable, Equatable {
        public let name: String
        public let disposition: Disposition
        public let isDirectory: Bool
        public let size: Int64
    }

    static let regenerableNames: Set<String> = StorageScan.junkDirectories.union([
        "build", "dist", "out", "bin", "obj", "target", ".cache",
    ])
    static let regenerableExtensions: Set<String> = ["o", "pyc", "class", "obj", "lock"]

    static func isRegenerable(_ name: String, isDirectory: Bool) -> Bool {
        if regenerableNames.contains(name) { return true }
        return !isDirectory && regenerableExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Classify the direct children of `folder` (which must be inside a git repo). Returns []
    /// when `folder` is not in a repo.
    public static func classify(_ folder: URL) async -> [Item] {
        guard OrganizePlanner.isInsideGitRepo(folder) else { return [] }
        let fm = FileManager.default
        guard
            let children = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
        else { return [] }
        let names = children.map(\.lastPathComponent).filter { $0 != ".git" }
        guard !names.isEmpty else { return [] }

        // `git ls-files` lists tracked files; the first path component of each result is a
        // tracked top-level entry. Anything else in the folder is untracked/ignored.
        let tracked = await trackedTopLevel(names, in: folder)

        var items: [Item] = []
        for url in children where url.lastPathComponent != ".git" {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let disposition: Disposition =
                tracked.contains(name)
                ? .tracked
                : (isRegenerable(name, isDirectory: isDir) ? .regenerable : .precious)
            let size =
                isDir
                ? DirectorySize.total(of: url).bytes
                : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            items.append(Item(name: name, disposition: disposition, isDirectory: isDir, size: size))
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func trackedTopLevel(_ names: [String], in folder: URL) async -> Set<String> {
        guard
            let (data, status, _) = try? await RemoteRunner.run(
                GitStatus.git, ["-C", folder.path, "ls-files", "-z", "--"] + names),
            status == 0
        else { return [] }
        var result = Set<String>()
        for entry in String(decoding: data, as: UTF8.self).split(separator: "\0") where !entry.isEmpty {
            result.insert(String(entry.split(separator: "/", maxSplits: 1).first ?? entry))
        }
        return result
    }
}
