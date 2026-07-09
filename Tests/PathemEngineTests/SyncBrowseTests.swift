import Foundation
import Testing

@testable import PathemEngine

@Suite struct SyncBrowseTests {
    @Test func descendMirrorsIntoSameNamedChild() {
        // Left goes /projA -> /projA/src; right at /projB should go to /projB/src.
        #expect(
            SyncBrowse.mirroredPath(
                driverFrom: "/a/projA", driverTo: "/a/projA/src", otherAt: "/a/projB")
                == "/a/projB/src")
    }

    @Test func descendTwoLevels() {
        #expect(
            SyncBrowse.mirroredPath(
                driverFrom: "/a/projA/src", driverTo: "/a/projA/src/lib", otherAt: "/a/projB/src")
                == "/a/projB/src/lib")
    }

    @Test func ascendMirrorsUp() {
        #expect(
            SyncBrowse.mirroredPath(
                driverFrom: "/a/projA/src", driverTo: "/a/projA", otherAt: "/a/projB/src")
                == "/a/projB")
    }

    @Test func siblingMove() {
        // /projA/x -> /projA/y mirrors /projB/x -> /projB/y (up one, down into y).
        #expect(
            SyncBrowse.mirroredPath(
                driverFrom: "/a/projA/x", driverTo: "/a/projA/y", otherAt: "/a/projB/x")
                == "/a/projB/y")
    }

    @Test func noCommonRootMirrorsAbsolutely() {
        // An absolute jump with no shared ancestor moves the other pane to the same place.
        #expect(
            SyncBrowse.mirroredPath(
                driverFrom: "/a/projA", driverTo: "/x/other", otherAt: "/a/projB")
                == "/x/other")
    }

    @Test func ascendToRoot() {
        #expect(
            SyncBrowse.mirroredPath(driverFrom: "/a/projA", driverTo: "/a", otherAt: "/a/projB")
                == "/a")
        #expect(
            SyncBrowse.mirroredPath(driverFrom: "/a", driverTo: "/", otherAt: "/b") == "/")
    }

    @Test func noMoveReturnsNil() {
        #expect(
            SyncBrowse.mirroredPath(driverFrom: "/a/x", driverTo: "/a/x", otherAt: "/a/y") == nil)
    }

    @Test func risingAboveOtherPaneRootReturnsNil() {
        // Driver rises 3 levels but the other pane only has 1 component: can't go above root.
        #expect(
            SyncBrowse.mirroredPath(driverFrom: "/a/b/c", driverTo: "/x", otherAt: "/a") == nil)
    }

    @Test func trailingSlashesAndDupSeparatorsAreTolerated() {
        #expect(
            SyncBrowse.mirroredPath(
                driverFrom: "/a/projA/", driverTo: "/a/projA//src", otherAt: "/a/projB/")
                == "/a/projB/src")
    }
}
