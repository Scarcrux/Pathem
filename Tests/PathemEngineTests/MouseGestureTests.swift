import CoreGraphics
import Foundation
import Testing

@testable import PathemEngine

@Suite struct MouseGestureTests {
    private func path(_ pts: [(CGFloat, CGFloat)]) -> [CGPoint] {
        pts.map { CGPoint(x: $0.0, y: $0.1) }
    }

    @Test func recognizesSingleDirections() {
        #expect(MouseGesture.reduce(path([(0, 0), (100, 0)])) == "R")
        #expect(MouseGesture.reduce(path([(0, 0), (-100, 0)])) == "L")
        #expect(MouseGesture.reduce(path([(0, 0), (0, 100)])) == "U")  // y-up
        #expect(MouseGesture.reduce(path([(0, 0), (0, -100)])) == "D")
    }

    @Test func recognizesCombosAndCollapses() {
        // Right then down, with intermediate points along the way.
        #expect(
            MouseGesture.reduce(path([(0, 0), (50, 0), (100, 0), (100, -50), (100, -100)])) == "RD")
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

@Suite struct SharedGestureCompatibilityTests {
    @Test func fifthDirectionPreservesPathemPrefix() {
        let points: [CGPoint] = [
            .zero, CGPoint(x: 18, y: 0), CGPoint(x: 18, y: 18),
            CGPoint(x: 0, y: 18), .zero, CGPoint(x: 18, y: 0),
        ]
        #expect(MouseGesture.reduce(points) == "RULD")
        #expect(MouseGesture.reduce([.zero, CGPoint(x: 17.99, y: 17.99)]) == "")
        #expect(MouseGesture.reduce([.zero, CGPoint(x: 18, y: 18)]) == "R")
    }
    @Test func streamingCaptureMatchesLegacyValidGeometryAndBoundsMemory() {
        // Independent historical geometry oracle; never used by production.
        func legacy(_ points: [CGPoint]) -> String {
            var anchor = points[0]
            var directions: [Character] = []
            for point in points.dropFirst() {
                let dx = point.x - anchor.x
                let dy = point.y - anchor.y
                if abs(dx) < 18 && abs(dy) < 18 { continue }
                let direction: Character =
                    abs(dx) >= abs(dy) ? (dx > 0 ? "R" : "L") : (dy > 0 ? "U" : "D")
                if directions.last != direction { directions.append(direction) }
                anchor = point
            }
            return String(directions.prefix(4))
        }
        var points: [CGPoint] = [.zero]
        for i in 1...10000 { points.append(CGPoint(x: i * 18, y: 0)) }
        points += [
            CGPoint(x: 180000, y: 18), CGPoint(x: 179982, y: 18), CGPoint(x: 179982, y: 0),
            CGPoint(x: 180000, y: 0),
        ]
        var capture = MouseGestureCapture(origin: points[0])
        for point in points.dropFirst() { capture.append(point) }
        #expect(capture.visualPointCount == 256)
        #expect(capture.visualPoints == Array(points.suffix(256)))
        #expect(capture.end() == legacy(points))
        #expect(capture.end() == nil)
        #expect(capture.visualPointCount == 0)
        #expect(MouseGesture.reduce(points) == legacy(points))
    }
    @Test func cancelAndInvalidCoordinatesDoNotBecomeRecognizedStrokes() {
        var capture = MouseGestureCapture(origin: .zero)
        capture.append(CGPoint(x: 100, y: 0))
        capture.cancel()
        #expect(capture.end() == nil)
        #expect(MouseGesture.reduce([.zero, CGPoint(x: CGFloat.infinity, y: 0)]) == "")
    }
    @Test func savedOverlayAndFlickDefaultsRemainCompatible() throws {
        let overlay = ["R": "nav.up", "DR": "", "UL": "tab.new"]
        let encoded = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode([String: String].self, from: encoded)
        let result = GestureMap.standard.merging(userBindings: decoded)
        #expect(result.commandID(for: "R") == "nav.up")
        #expect(result.commandID(for: "DR") == nil)
        #expect(GestureMap.overlay(forEffective: result.bindings) == overlay)
        #expect(DragGestureMap.standard.merging(userBindings: ["D": ""]).commandID(for: "D") == nil)
        #expect(DragGestureMap.standard.commandID(for: "R") == "files.copyToOtherPane")
        #expect(MouseGesture.reduce([.zero, CGPoint(x: 43.99, y: 0)], minSegment: 44) == "")
        #expect(MouseGesture.reduce([.zero, CGPoint(x: 44, y: 0)], minSegment: 44) == "R")
    }
}
