import Foundation
import Testing

@testable import PathemEngine

@Suite struct PairedFoldersTests {
    /// A real tree: src/{a/deep,b} and dst/{a/deep}, so "b" has no counterpart.
    private func makeTree() throws -> (root: URL, pair: FolderPair) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pairs-\(UUID().uuidString)")
        for sub in ["src/a/deep", "src/b", "dst/a/deep"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let pair = FolderPair(
            left: root.appendingPathComponent("src").path,
            right: root.appendingPathComponent("dst").path)
        return (root, pair)
    }

    private func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    @Test func relativePathComparesWholeComponents() {
        let root = URL(fileURLWithPath: "/a/b")
        #expect(PairedFolders.relativePath(of: URL(fileURLWithPath: "/a/b"), under: root) == [])
        #expect(
            PairedFolders.relativePath(of: URL(fileURLWithPath: "/a/b/c/d"), under: root) == [
                "c", "d",
            ])
        #expect(PairedFolders.relativePath(of: URL(fileURLWithPath: "/a/bc"), under: root) == nil)
        #expect(PairedFolders.relativePath(of: URL(fileURLWithPath: "/a"), under: root) == nil)
    }

    @Test func followingIntoASubfolderMapsToTheSameRelativePath() throws {
        let (root, pair) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: pair.left)
        let dst = URL(fileURLWithPath: pair.right)
        let result = PairedFolders.counterpart(
            pairs: [pair], moved: .left, newFolder: src.appendingPathComponent("a/deep"),
            otherFolder: dst, exists: isDir)
        #expect(result == .follow(dst.appendingPathComponent("a/deep").standardizedFileURL))
    }

    @Test func goingUpFollowsToo() throws {
        let (root, pair) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: pair.left)
        let dst = URL(fileURLWithPath: pair.right)
        // The RIGHT pane went up from dst/a/deep to dst/a; the left pane was at src/a/deep.
        let result = PairedFolders.counterpart(
            pairs: [pair], moved: .right, newFolder: dst.appendingPathComponent("a"),
            otherFolder: src.appendingPathComponent("a/deep"), exists: isDir)
        #expect(result == .follow(src.appendingPathComponent("a").standardizedFileURL))
    }

    @Test func aMissingCounterpartIsNoMatchAndTheOtherPaneStays() throws {
        let (root, pair) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: pair.left)
        let dst = URL(fileURLWithPath: pair.right)
        let result = PairedFolders.counterpart(
            pairs: [pair], moved: .left, newFolder: src.appendingPathComponent("b"),
            otherFolder: dst, exists: isDir)
        #expect(result == .noMatch)
    }

    @Test func leavingThePairOrNotBeingPairedIsNotApplicable() throws {
        let (root, pair) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: pair.left)
        let dst = URL(fileURLWithPath: pair.right)
        #expect(
            PairedFolders.counterpart(
                pairs: [pair], moved: .left, newFolder: root, otherFolder: dst, exists: isDir)
                == .notApplicable)
        #expect(
            PairedFolders.counterpart(
                pairs: [pair], moved: .left, newFolder: src, otherFolder: root, exists: isDir)
                == .notApplicable)
        #expect(
            PairedFolders.counterpart(
                pairs: [], moved: .left, newFolder: src, otherFolder: dst, exists: isDir)
                == .notApplicable)
    }

    @Test func theDeepestMatchingPairWins() throws {
        let (root, outer) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // A second, deeper pair maps src/a to dst/a/deep.
        let inner = FolderPair(
            left: root.appendingPathComponent("src/a").path,
            right: root.appendingPathComponent("dst/a/deep").path)
        let result = PairedFolders.counterpart(
            pairs: [outer, inner], moved: .left,
            newFolder: root.appendingPathComponent("src/a/deep"),
            otherFolder: root.appendingPathComponent("dst/a/deep"), exists: isDir)
        // Via the inner pair, src/a/deep is "deep" below src/a, so dst/a/deep/deep (absent).
        // The outer pair alone would have said dst/a/deep and followed.
        #expect(result == .noMatch)
    }

    @Test func sameFolderUsesThePairThenFallsBackToTheSiblingName() throws {
        let (root, pair) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: pair.left)
        let dst = URL(fileURLWithPath: pair.right)
        #expect(
            PairedFolders.sameFolder(
                pairs: [pair], active: .left, activeFolder: src.appendingPathComponent("a/deep"),
                otherFolder: dst, exists: isDir)
                == dst.appendingPathComponent("a/deep").standardizedFileURL)
        // No pair and the other parent (dst) has no folder named like the active one.
        #expect(
            PairedFolders.sameFolder(
                pairs: [], active: .left, activeFolder: root.appendingPathComponent("src"),
                otherFolder: root.appendingPathComponent("dst/a"), exists: isDir) == nil)
        // No pair: the other pane's parent holds a folder with the active folder's name.
        let found = PairedFolders.sameFolder(
            pairs: [], active: .left, activeFolder: src.appendingPathComponent("a"),
            otherFolder: dst.appendingPathComponent("b"), exists: isDir)
        #expect(found == dst.appendingPathComponent("a").standardizedFileURL)
    }

    @Test func addingAPairIgnoresDuplicates() {
        let pair = FolderPair(left: "/x/l", right: "/x/r")
        var pairs = PairedFolders.adding(pair, to: [])
        pairs = PairedFolders.adding(FolderPair(left: "/x/l/", right: "/x/./r"), to: pairs)
        #expect(pairs.count == 1)
        pairs = PairedFolders.adding(FolderPair(left: "/x/r", right: "/x/l"), to: pairs)
        #expect(pairs.count == 2)  // the reverse orientation is a different pair
    }

    @Test func oldPreferencesDecodeWithNoPairs() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(prefs.pairedFolders.isEmpty)
        var p = Preferences.default
        p.pairedFolders = [FolderPair(left: "/a", right: "/b")]
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        #expect(back.pairedFolders == p.pairedFolders)
    }
}
