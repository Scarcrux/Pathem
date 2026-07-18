import Testing

@testable import PathemEngine

@Suite struct BonjourHostTests {
    @Test func stripsTheTrailingRootDot() {
        // The exact shape that caused the "Couldn't mount ..." failure.
        #expect(BonjourHost.normalized("studios-macbook-pro.local.") == "studios-macbook-pro.local")
        #expect(BonjourHost.normalized("Studio-Mac.local.") == "Studio-Mac.local")
    }

    @Test func leavesCleanNamesUnchanged() {
        #expect(BonjourHost.normalized("Studio-Mac.local") == "Studio-Mac.local")
        #expect(BonjourHost.normalized("192.168.1.5") == "192.168.1.5")  // dots are interior, not trailing
        #expect(BonjourHost.normalized("") == "")
    }

    @Test func handlesEdgeCases() {
        #expect(BonjourHost.normalized("host..") == "host")  // more than one trailing dot
        #expect(BonjourHost.normalized(".") == "")
        // Idempotent: normalizing an already-normalized name is a no-op.
        let once = BonjourHost.normalized("Mac.local.")
        #expect(BonjourHost.normalized(once) == once)
    }
}
