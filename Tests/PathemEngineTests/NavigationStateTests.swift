import Foundation
import Testing

@testable import PathemEngine

@Suite struct NavigationStateTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func startsWithEmptyHistory() {
        let s = NavigationState(current: url("/a/b/c"))
        #expect(s.current.path == "/a/b/c")
        #expect(!s.canGoBack)
        #expect(!s.canGoForward)
    }

    @Test func goPushesBackAndClearsForward() {
        var s = NavigationState(current: url("/a"))
        s.go(to: url("/a/b"))
        #expect(s.current.path == "/a/b")
        #expect(s.canGoBack)
        #expect(!s.canGoForward)

        _ = s.goBack()
        #expect(s.current.path == "/a")
        #expect(s.canGoForward)

        s.go(to: url("/a/x"))  // navigating forward-from-here clears the forward stack
        #expect(s.current.path == "/a/x")
        #expect(!s.canGoForward)
    }

    @Test func backForwardRoundTrip() {
        var s = NavigationState(current: url("/a"))
        s.go(to: url("/a/b"))
        s.go(to: url("/a/b/c"))

        // (mutating calls are pulled out of #expect — the macro captures its
        // argument immutably and can't call a mutating method inline.)
        let b1 = s.goBack(); #expect(b1); #expect(s.current.path == "/a/b")
        let b2 = s.goBack(); #expect(b2); #expect(s.current.path == "/a")
        let b3 = s.goBack(); #expect(!b3)  // nothing left to go back to

        let f1 = s.goForward(); #expect(f1); #expect(s.current.path == "/a/b")
        let f2 = s.goForward(); #expect(f2); #expect(s.current.path == "/a/b/c")
        let f3 = s.goForward(); #expect(!f3)
    }

    @Test func goToSameDirectoryIsNoOp() {
        var s = NavigationState(current: url("/a/b"))
        s.go(to: url("/a/b/"))  // standardizes equal
        #expect(!s.canGoBack)
    }

    @Test func goUpAndRootHasNoParent() {
        var s = NavigationState(current: url("/a/b"))
        let up = s.goUp(); #expect(up); #expect(s.current.path == "/a")

        var root = NavigationState(current: url("/"))
        #expect(root.parent == nil)
        let rootUp = root.goUp(); #expect(!rootUp)
    }
}
