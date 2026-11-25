import Foundation
import Testing

@testable import PathemEngine

@Suite struct FolderTreeTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foldertree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test func revealChainRunsFromRootDownToTarget() {
        let root = URL(fileURLWithPath: "/Users/me")
        let target = URL(fileURLWithPath: "/Users/me/Code/app/Sources")
        let chain = FolderTree.revealChain(root: root, target: target)
        #expect(
            chain?.map(\.path) == [
                "/Users/me", "/Users/me/Code", "/Users/me/Code/app", "/Users/me/Code/app/Sources",
            ])
    }

    @Test func revealChainOfTheRootIsJustTheRoot() {
        let root = URL(fileURLWithPath: "/Users/me")
        #expect(FolderTree.revealChain(root: root, target: root)?.map(\.path) == ["/Users/me"])
    }

    @Test func revealChainIsNilOutsideTheRoot() {
        let root = URL(fileURLWithPath: "/Users/me")
        #expect(
            FolderTree.revealChain(root: root, target: URL(fileURLWithPath: "/Users/meow")) == nil)
        #expect(FolderTree.revealChain(root: root, target: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func revealChainFromFilesystemRoot() {
        let chain = FolderTree.revealChain(
            root: URL(fileURLWithPath: "/"), target: URL(fileURLWithPath: "/Volumes/Data/x"))
        #expect(chain?.map(\.path) == ["/", "/Volumes", "/Volumes/Data", "/Volumes/Data/x"])
    }

    @Test func rootPrefersHomeWhenInsideItElseVolumeRoot() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(
            FolderTree.root(for: URL(fileURLWithPath: "/Users/me/Documents"), home: home).path
                == "/Users/me")
        #expect(FolderTree.root(for: URL(fileURLWithPath: "/Applications"), home: home).path == "/")
    }

    @Test func subfoldersListsFoldersOnlySortedAndHonorsHidden() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for name in ["b", "A", "file10", ".hidden"] {
            if name.hasPrefix("file") {
                fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
            } else {
                try fm.createDirectory(
                    at: dir.appendingPathComponent(name), withIntermediateDirectories: false)
            }
        }
        let shown = FolderTree.subfolders(of: dir, includingHidden: false)
        #expect(shown.folders.map(\.name) == ["A", "b"])
        #expect(shown.isReadable)
        let all = FolderTree.subfolders(of: dir, includingHidden: true)
        #expect(all.folders.map(\.name) == [".hidden", "A", "b"])
    }

    @Test func unreadableFolderReportsNotReadableInsteadOfThrowing() throws {
        let dir = try temp()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        let result = FolderTree.subfolders(of: dir, includingHidden: false)
        #expect(result.folders.isEmpty)
        #expect(!result.isReadable)
    }

    @Test func folderTreeWidthClampsAndPersists() throws {
        #expect(FolderTree.clampedWidth(10) == FolderTree.minWidth)
        #expect(FolderTree.clampedWidth(9999) == FolderTree.maxWidth)
        #expect(Preferences().showFolderTree == false)
        var prefs = Preferences()
        prefs.showFolderTree = true
        prefs.folderTreeWidth = 300
        let restored = try JSONDecoder().decode(
            Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored.showFolderTree && restored.folderTreeWidth == 300)
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(legacy.showFolderTree == false)
        #expect(legacy.folderTreeWidth == FolderTree.defaultWidth)
    }
}
