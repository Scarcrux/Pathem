import Foundation
import Testing

@testable import PathemEngine

@Suite struct ShelfModelTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func addsInOrderAndDeduplicates() {
        var shelf = ShelfModel()
        let added = shelf.add([url("/a/x.txt"), url("/b/y.txt")])
        #expect(added)
        #expect(shelf.items.map(\.path) == ["/a/x.txt", "/b/y.txt"])
        // Re-adding an existing item is a no-op and returns false.
        let dup = shelf.add([url("/a/x.txt")])
        #expect(dup == false)
        #expect(shelf.count == 2)
        // A new one still appends after the existing items.
        let more = shelf.add([url("/a/x.txt"), url("/c/z.txt")])
        #expect(more)
        #expect(shelf.items.last?.path == "/c/z.txt")
    }

    @Test func dedupesEquivalentSpellings() {
        var shelf = ShelfModel()
        shelf.add([url("/a/./x.txt")])
        shelf.add([url("/a/b/../x.txt")])  // standardizes to /a/x.txt
        #expect(shelf.count == 1)
        #expect(shelf.contains(url("/a/x.txt")))
    }

    @Test func removeAndClear() {
        var shelf = ShelfModel(items: [url("/a/x.txt"), url("/b/y.txt")])
        shelf.remove(url("/a/x.txt"))
        #expect(shelf.items.map(\.path) == ["/b/y.txt"])
        shelf.removeAll()
        #expect(shelf.isEmpty)
    }
}
