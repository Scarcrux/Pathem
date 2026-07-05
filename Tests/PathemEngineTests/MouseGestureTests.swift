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

    // MARK: - Super-drag flick

    @Test func flickDirectionUsesThreshold() {
        // A flick is start->end reduced with a larger minSegment; a clear cardinal fires,
        // movement under the threshold does not (so a normal short drag isn't a flick).
        let flick = { (dx: CGFloat, dy: CGFloat) in
            MouseGesture.reduce([.zero, CGPoint(x: dx, y: dy)], minSegment: 40)
        }
        #expect(flick(80, 0) == "R")
        #expect(flick(-80, 0) == "L")
        #expect(flick(0, 80) == "U")  // y-up
        #expect(flick(0, -80) == "D")
        #expect(flick(30, 10) == "")  // under threshold: not a flick
    }

    @Test func dragGestureMapDefaultsAndOverlay() {
        let map = DragGestureMap.standard
        #expect(map.commandID(for: "U") == "files.open")
        #expect(map.commandID(for: "D") == "files.trash")
        #expect(map.commandID(for: "R") == "files.copyToOtherPane")
        #expect(map.commandID(for: "L") == "files.moveToOtherPane")
        // Remap up to Quick Look and unbind down; the overlay takes effect.
        let remapped = map.merging(userBindings: ["U": "view.quickLook", "D": ""])
        #expect(remapped.commandID(for: "U") == "view.quickLook")
        #expect(remapped.commandID(for: "D") == nil)
    }
}
