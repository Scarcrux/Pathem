import Foundation
import Testing

@testable import PathemEngine

@Suite("Sidebar model")
struct SidebarTests {
    // Fixed ids so reordering assertions are deterministic.
    private func sample() -> Sidebar {
        let a = Sidebar.Item(id: UUID(0), name: "A", icon: "doc", path: "/a")
        let b = Sidebar.Item(id: UUID(1), name: "B", icon: "doc", path: "/b")
        let c = Sidebar.Item(id: UUID(2), name: "C", icon: "doc", path: "/c")
        let g1 = Sidebar.Group(id: UUID(10), title: "One", items: [a, b])
        let g2 = Sidebar.Group(id: UUID(11), title: "Two", items: [c])
        return Sidebar(groups: [g1, g2])
    }

    @Test func defaultHasFavorites() {
        let s = Sidebar.makeDefault(home: URL(fileURLWithPath: "/Users/x"))
        #expect(s.groups.count == 1)
        #expect(s.groups[0].title == "Favorites")
        #expect(s.groups[0].items.map(\.name) == ["Home", "Desktop", "Documents", "Downloads", "Applications"])
        #expect(s.groups[0].items[0].path == "/Users/x")
    }

    @Test func codableRoundTrip() throws {
        let s = sample()
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Sidebar.self, from: data)
        #expect(back == s)
    }

    @Test func addAndRemoveItem() {
        var s = sample()
        let new = Sidebar.Item(id: UUID(3), name: "D", icon: "star", path: "/d")
        s.addItem(new, toGroup: UUID(11))
        #expect(s.groups[1].items.map(\.name) == ["C", "D"])
        s.removeItem(UUID(2))
        #expect(s.groups[1].items.map(\.name) == ["D"])
    }

    @Test func renameAndReicon() {
        var s = sample()
        s.renameItem(UUID(0), to: "Alpha")
        s.setIcon(UUID(0), to: "house")
        #expect(s.groups[0].items[0].name == "Alpha")
        #expect(s.groups[0].items[0].icon == "house")
    }

    @Test func moveItemWithinGroupReorders() {
        var s = sample()
        // Move A (index 0) to the end of its own group.
        s.moveItem(UUID(0), toGroup: UUID(10), at: 2)
        #expect(s.groups[0].items.map(\.name) == ["B", "A"])
    }

    @Test func moveItemAcrossGroups() {
        var s = sample()
        // Move A into group Two at index 0.
        s.moveItem(UUID(0), toGroup: UUID(11), at: 0)
        #expect(s.groups[0].items.map(\.name) == ["B"])
        #expect(s.groups[1].items.map(\.name) == ["A", "C"])
    }

    @Test func groupCrudAndReorder() {
        var s = sample()
        let gid = s.addGroup(title: "Three")
        #expect(s.groups.map(\.title) == ["One", "Two", "Three"])
        s.renameGroup(gid, to: "III")
        #expect(s.groups[2].title == "III")
        s.moveGroup(gid, to: 0)
        #expect(s.groups.map(\.title) == ["III", "One", "Two"])
        s.removeGroup(gid)
        #expect(s.groups.map(\.title) == ["One", "Two"])
    }
}

extension UUID {
    /// Deterministic uuid from a small int for tests.
    fileprivate init(_ n: Int) {
        let hex = String(format: "%032x", n)
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<next], radix: 16)!)
            i = next
        }
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
