import Foundation
import Testing

@testable import PathemEngine

@Suite struct FolderTreeRootsTests {
    private let home = URL(fileURLWithPath: "/Users/me")

    private func roots(
        volumes: [(URL, String)] = [], pinned: [String] = []
    ) -> [FolderTree.Root] {
        FolderTree.roots(
            home: home, homeName: "Home",
            volumes: volumes.map { (url: $0.0, name: $0.1) },
            pinned: pinned.map { URL(fileURLWithPath: $0) })
    }

    @Test func rootsAreHomeThenVolumesThenPins() {
        let list = roots(
            volumes: [
                (URL(fileURLWithPath: "/"), "Macintosh HD"),
                (URL(fileURLWithPath: "/Volumes/Backup"), "Backup"),
            ], pinned: ["/Users/me/Code/app"])
        #expect(list.map(\.name) == ["Home", "Macintosh HD", "Backup", "app"])
        #expect(list.map(\.kind) == [.home, .volume, .volume, .pinned])
    }

    @Test func aFolderIsNeverARootTwice() {
        let list = roots(
            volumes: [(home, "Same as home")],
            pinned: ["/Users/me", "/Volumes/Backup/", "/Users/me/Code", "/Users/me/Code"])
        #expect(list.map(\.url.path) == ["/Users/me", "/Volumes/Backup", "/Users/me/Code"])
    }

    @Test func deepestHomeOrVolumeOwnsTheTarget() {
        let list = roots(
            volumes: [
                (URL(fileURLWithPath: "/"), "Macintosh HD"),
                (URL(fileURLWithPath: "/Volumes/Backup"), "Backup"),
            ], pinned: ["/Users/me/Code/app"])
        func name(_ path: String) -> String? {
            FolderTree.rootIndex(containing: URL(fileURLWithPath: path), in: list)
                .map { list[$0].name }
        }
        #expect(name("/Users/me/Documents") == "Home")
        #expect(name("/Users/me/Code/app/Sources") == "Home")  // pins are shortcuts, Home owns it
        #expect(name("/Volumes/Backup/photos") == "Backup")
        #expect(name("/Library") == "Macintosh HD")
        #expect(FolderTree.rootIndex(containing: URL(fileURLWithPath: "/x"), in: []) == nil)
    }

    @Test func aPinOwnsOnlyWhatNoOtherRootContains() {
        let list = FolderTree.roots(
            home: home, homeName: "Home", volumes: [],
            pinned: [URL(fileURLWithPath: "/opt/tools")])
        #expect(
            FolderTree.rootIndex(containing: URL(fileURLWithPath: "/opt/tools/bin"), in: list)
                == 1)
    }

    @Test func siblingWithSharedPrefixIsNotInsideTheRoot() {
        let list = roots()
        #expect(
            FolderTree.rootIndex(containing: URL(fileURLWithPath: "/Users/meow"), in: list) == nil)
    }

    @Test func pinAndUnpinNormalizeAndDedupe() {
        var state = FolderTreeState()
        let first = state.pin(URL(fileURLWithPath: "/Users/me/Code/"))
        let again = state.pin(URL(fileURLWithPath: "/Users/me/Code"))
        let volumeRoot = state.pin(URL(fileURLWithPath: "/"))
        #expect(first && !again && !volumeRoot)
        #expect(state.isPinned(URL(fileURLWithPath: "/Users/me/Code/../Code")))
        let removed = state.unpin(URL(fileURLWithPath: "/Users/me/Code"))
        let removedAgain = state.unpin(URL(fileURLWithPath: "/Users/me/Code"))
        #expect(removed && !removedAgain)
        #expect(state.pinned.isEmpty)
    }

    @Test func expansionIsRecordedCollapsedAndCapped() {
        var state = FolderTreeState()
        let a = URL(fileURLWithPath: "/a")
        state.setExpanded(a, true)
        state.setExpanded(a, true)
        #expect(state.expanded == ["/a"])
        state.setExpanded(a, false)
        #expect(state.expanded.isEmpty)
        for index in 0..<(FolderTreeState.maxExpanded + 25) {
            state.setExpanded(URL(fileURLWithPath: "/f\(index)"), true)
        }
        #expect(state.expanded.count == FolderTreeState.maxExpanded)
        #expect(state.expanded.last == "/f\(FolderTreeState.maxExpanded + 24)")
        #expect(!state.expanded.contains("/f0"))
    }

    @Test func restoreOrderOpensParentsFirst() {
        var state = FolderTreeState()
        state.setExpanded(URL(fileURLWithPath: "/a/b/c"), true)
        state.setExpanded(URL(fileURLWithPath: "/a"), true)
        state.setExpanded(URL(fileURLWithPath: "/a/b"), true)
        #expect(state.expandedShallowFirst.map(\.path) == ["/a", "/a/b", "/a/b/c"])
    }

    @Test func stateRoundTripsThroughPreferences() throws {
        var prefs = Preferences()
        prefs.folderTreeState.pin(URL(fileURLWithPath: "/Users/me/Code"))
        prefs.folderTreeState.setExpanded(URL(fileURLWithPath: "/Users/me"), true)
        let restored = try JSONDecoder().decode(
            Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored.folderTreeState == prefs.folderTreeState)
    }

    @Test func oldConfigsDecodeWithEmptyTreeState() throws {
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(legacy.folderTreeState == FolderTreeState())
        let partial = try JSONDecoder().decode(FolderTreeState.self, from: Data("{}".utf8))
        #expect(partial.pinned.isEmpty && partial.expanded.isEmpty)
        let dupes = try JSONDecoder().decode(
            FolderTreeState.self, from: Data(#"{"pinned":["/a","/a",""]}"#.utf8))
        #expect(dupes.pinned == ["/a"])
    }
}
