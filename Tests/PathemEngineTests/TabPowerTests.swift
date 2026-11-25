import Foundation
import Testing

@testable import PathemEngine

@Suite struct TabPowerTests {
    private func snap(_ path: String, locked: Bool = false) -> TabSnapshot {
        TabSnapshot(path: path, format: nil, locked: locked, back: [], forward: [])
    }

    // MARK: Closed-tab stack

    @Test func closedStackIsLastInFirstOutAndCapsAtTwenty() {
        var stack = ClosedTabStack()
        for i in 0..<25 { stack.push(snap("/t/\(i)")) }
        #expect(stack.count == 20)
        let newest = stack.pop()
        let next = stack.pop()
        #expect(newest?.path == "/t/24")  // newest first
        #expect(next?.path == "/t/23")
        // The five oldest fell off the far end.
        var last: String?
        while let s = stack.pop() { last = s.path }
        #expect(last == "/t/5")
        #expect(stack.isEmpty)
    }

    @Test func reopenSkipsFoldersThatNoLongerExist() {
        var stack = ClosedTabStack()
        stack.push(snap("/gone/a"))
        stack.push(snap("/here/b"))
        stack.push(snap("/gone/c"))
        let got = stack.popRestorable { $0.hasPrefix("/here") }
        #expect(got?.path == "/here/b")
        // /gone/c was dropped on the way; /gone/a is stale and is dropped by the next ask.
        let none = stack.popRestorable { $0.hasPrefix("/here") }
        #expect(none == nil)
        #expect(stack.isEmpty)
    }

    @Test func snapshotKeepsFormatAndHistory() throws {
        var format = ViewFormat.default
        format.viewMode = .gallery
        format.sortKey = .size
        format.ascending = false
        let original = TabSnapshot(
            path: "/a/b", format: format, locked: true, back: ["/a", "/"], forward: ["/a/b/c"])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        #expect(back == original)
        #expect(back.format?.viewMode == .gallery)
        #expect(back.format?.sortKey == .size)
    }

    @Test func snapshotDecodesFromJustAPath() throws {
        let s = try JSONDecoder().decode(TabSnapshot.self, from: Data(#"{"path":"/x"}"#.utf8))
        #expect(s.path == "/x")
        #expect(s.locked == false)
        #expect(s.format == nil)
        #expect(s.back.isEmpty && s.forward.isEmpty)
    }

    @Test func navigationStateRestoresItsStacks() {
        let nav = NavigationState(
            current: URL(fileURLWithPath: "/a/b"),
            back: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/a")],
            forward: [URL(fileURLWithPath: "/a/b/c")])
        #expect(nav.canGoBack && nav.canGoForward)
        var copy = nav
        _ = copy.goBack()
        #expect(copy.current.path == "/a")  // the most recent back entry is last
    }

    // MARK: Lock policy

    @Test func lockedTabOpensOtherFoldersInANewTab() {
        let here = URL(fileURLWithPath: "/a")
        let there = URL(fileURLWithPath: "/a/b")
        #expect(TabLockPolicy.navigation(locked: true, current: here, target: there) == .newTab)
        #expect(TabLockPolicy.navigation(locked: false, current: here, target: there) == .inPlace)
        // Re-entering the same folder (a refresh-style navigate) is never a new tab.
        #expect(TabLockPolicy.navigation(locked: true, current: here, target: here) == .inPlace)
        // Trailing slash and dot segments compare equal.
        #expect(
            TabLockPolicy.navigation(
                locked: true, current: here, target: URL(fileURLWithPath: "/a/b/..")) == .inPlace)
    }

    @Test func closeSkipsLockedTabsAndCloseOthersKeepsThem() {
        let locks = [false, true, false, true, false]
        #expect(TabLockPolicy.canClose(locks, index: 0))
        #expect(!TabLockPolicy.canClose(locks, index: 1))
        #expect(!TabLockPolicy.canClose(locks, index: 9))  // out of range
        #expect(TabLockPolicy.indicesToCloseOthers(locks, keeping: 2) == [0, 4])
        // Keeping a locked tab is fine too; the other locked one still stays.
        #expect(TabLockPolicy.indicesToCloseOthers(locks, keeping: 1) == [0, 2, 4])
    }

    @Test func lockFlagsArePaddedOrTrimmedToTheTabCount() {
        #expect(TabLockPolicy.normalized([true], count: 3) == [true, false, false])
        #expect(TabLockPolicy.normalized([true, true, true], count: 2) == [true, true])
        #expect(TabLockPolicy.normalized([], count: 0).isEmpty)
    }

    // MARK: MRU switcher

    @Test func mruOrderPutsTheLatestFirst() {
        var order = TabSwitcherOrder<String>()
        order.touch("a")
        order.touch("b")
        order.touch("c")
        #expect(order.order == ["c", "b", "a"])
        order.touch("a")
        #expect(order.order == ["a", "c", "b"])
        order.remove("c")
        #expect(order.order == ["a", "b"])
    }

    @Test func syncDropsDeadAndAppendsNewcomers() {
        var order = TabSwitcherOrder<String>()
        order.touch("a")
        order.touch("b")  // b, a
        order.sync(live: ["a", "n", "b"])
        #expect(order.order == ["b", "a", "n"])  // known keep MRU rank, new ones trail
        order.sync(live: ["n"])
        #expect(order.order == ["n"])
    }

    @Test func switcherStartsOnThePreviousTabAndWraps() {
        let order = ["cur", "prev", "older"]
        var forward = TabSwitcherSelection(order: order, reverse: false)
        #expect(forward?.chosen == "prev")
        forward?.advance(reverse: false)
        #expect(forward?.chosen == "older")
        forward?.advance(reverse: false)
        #expect(forward?.chosen == "cur")  // wraps through the current tab
        forward?.advance(reverse: true)
        #expect(forward?.chosen == "older")

        let backward = TabSwitcherSelection(order: order, reverse: true)
        #expect(backward?.chosen == "older")  // Ctrl-Shift-Tab starts at the far end
    }

    @Test func switcherNeedsAtLeastTwoTabs() {
        #expect(TabSwitcherSelection(order: ["only"], reverse: false) == nil)
        #expect(TabSwitcherSelection<String>(order: [], reverse: true) == nil)
    }

    // MARK: Tab groups

    private func group(_ name: String) -> TabGroup {
        TabGroup(
            name: name, left: [snap("/l", locked: true)], leftActive: 0, right: [snap("/r")],
            rightActive: 0)
    }

    @Test func savingAGroupReplacesTheSameNameIgnoringCase() {
        var store = TabGroupStore()
        store.save(group("Work"))
        store.save(group("Home"))
        var replaced = group("work")
        replaced.leftActive = 0
        replaced.left = [snap("/other")]
        store.save(replaced)
        #expect(store.groups.map(\.name) == ["Home", "work"])
        #expect(store.group(named: "WORK")?.left.first?.path == "/other")
    }

    @Test func renameRejectsEmptyAndTakenNames() {
        var store = TabGroupStore()
        store.save(group("A"))
        store.save(group("B"))
        let blank = store.rename("A", to: "  ")
        let taken = store.rename("A", to: "b")  // taken, case-insensitively
        let missing = store.rename("Nope", to: "C")
        #expect(!blank && !taken && !missing)
        let renamed = store.rename("A", to: " Alpha ")
        #expect(renamed)
        #expect(store.groups.map(\.name) == ["Alpha", "B"])
        // Changing only the case of its own name is allowed.
        let recased = store.rename("B", to: "b")
        #expect(recased)
    }

    @Test func deleteRemovesByName() {
        var store = TabGroupStore()
        store.save(group("A"))
        store.delete(named: "a")
        #expect(store.groups.isEmpty)
    }

    @Test func groupRoundTripsLocksAndActiveTab() throws {
        var g = group("Work")
        g.rightActive = 3
        let back = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(g))
        #expect(back == g)
        #expect(back.left.first?.locked == true)
        #expect(back.rightActive == 3)
    }

    @Test func oldOrEmptyGroupFilesDecodeToDefaults() throws {
        let store = try JSONDecoder().decode(TabGroupStore.self, from: Data("{}".utf8))
        #expect(store.groups.isEmpty)
        let g = try JSONDecoder().decode(TabGroup.self, from: Data(#"{"name":"X"}"#.utf8))
        #expect(g.left.isEmpty && g.right.isEmpty && g.leftActive == 0 && g.rightActive == 0)
    }
}
