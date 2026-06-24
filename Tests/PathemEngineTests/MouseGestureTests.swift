import CoreGraphics
import Testing

@testable import PathemEngine

@Suite struct MouseGestureTests {
    private func path(_ pts: [(CGFloat, CGFloat)]) -> [CGPoint] { pts.map { CGPoint(x: $0.0, y: $0.1) } }

    @Test func recognizesSingleDirections() {
        #expect(MouseGesture.reduce(path([(0, 0), (100, 0)])) == "R")
        #expect(MouseGesture.reduce(path([(0, 0), (-100, 0)])) == "L")
        #expect(MouseGesture.reduce(path([(0, 0), (0, 100)])) == "U")  // y-up
        #expect(MouseGesture.reduce(path([(0, 0), (0, -100)])) == "D")
    }

    @Test func recognizesCombosAndCollapses() {
        // Right then down, with intermediate points along the way.
        #expect(MouseGesture.reduce(path([(0, 0), (50, 0), (100, 0), (100, -50), (100, -100)])) == "RD")
    }

    @Test func tinyMovementIsNotAGesture() {
        // Jitter under the threshold yields no gesture, so a right-click shows its menu.
        #expect(MouseGesture.reduce(path([(0, 0), (3, 2), (1, -1)])) == "")
    }

    @Test func overlayRoundTrips() {
        var effective = GestureMap.defaultBindings
        effective["R"] = "nav.up"  // change
        effective["DL"] = "files.newFolder"  // add
        effective["U"] = nil  // remove a default
        let overlay = GestureMap.overlay(forEffective: effective)
        #expect(GestureMap.standard.merging(userBindings: overlay).bindings == effective)
    }
}
