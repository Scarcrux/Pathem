import Foundation
import Testing

@testable import PathemEngine

@Suite struct CollectionsTests {
    @Test func addCreatesDedupesAndAppends() {
        var store = Collections()
        store.add(["/a", "/b"], to: "Project")
        store.add(["/b", "/c"], to: "Project")  // /b is a dup
        #expect(store.collection(named: "Project")?.paths == ["/a", "/b", "/c"])
    }

    @Test func removePathAndCollection() {
        var store = Collections(collections: [FileCollection(name: "X", paths: ["/a", "/b"])])
        store.remove("/a", from: "X")
        #expect(store.collection(named: "X")?.paths == ["/b"])
        store.removeCollection(named: "X")
        #expect(store.collection(named: "X") == nil)
    }

    @Test func tolerantDecode() throws {
        let store = try JSONDecoder().decode(
            Collections.self, from: Data(#"{"collections":[{"name":"A"}]}"#.utf8))
        #expect(store.collection(named: "A")?.paths.isEmpty == true)
        #expect(try JSONDecoder().decode(Collections.self, from: Data("{}".utf8)).collections.isEmpty)
    }
}
