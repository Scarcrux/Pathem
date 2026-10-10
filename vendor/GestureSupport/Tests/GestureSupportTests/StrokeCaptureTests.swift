import XCTest

@testable import GestureSupport

final class StrokeCaptureTests: XCTestCase {
    private func sample(_ x: Double, _ y: Double, _ t: Double) -> StrokeSample {
        StrokeSample(x: x, y: y, timestamp: t)
    }
    func testExplicitOverflowPoliciesDiscriminateSameTrace() throws {
        for policy in [StrokeOverflowPolicy.reject, .prefix] {
            var capture = try StrokeCapture(
                origin: sample(0, 0, 0), overflow: policy, timeoutReason: "timeout")
            for point in [sample(18, 0, 1), sample(18, 18, 2), sample(0, 18, 3), sample(0, 0, 4)] {
                capture.move(point)
            }
            let result = capture.release(sample(18, 0, 5))
            XCTAssertEqual(
                result,
                policy == .reject
                    ? .rejected(.segmentLimit) : .recognized([.right, .up, .left, .down]))
            XCTAssertNil(capture.release(sample(18, 0, 6)))
            XCTAssertEqual(capture.visualPointCount, 0)
        }
    }
    func testThresholdJitterCollapseAndBoundedChronologicalTrail() throws {
        var capture = try StrokeCapture(origin: sample(0, 0, 0), timeoutReason: "timeout")
        capture.move(sample(17.99, 17.99, 1))
        XCTAssertTrue(capture.directions.isEmpty)
        for i in 1...10000 { capture.move(sample(Double(i) * 18, 0, Double(i + 1))) }
        XCTAssertEqual(capture.visualPointCount, 256)
        XCTAssertEqual(capture.visualPoints.map(\.x), (9745...10000).map { Double($0) * 18 })
        XCTAssertEqual(
            capture.release(sample(180000 - 18, 0, 10002)), .recognized([.right, .left]))
    }
    func testCancellationTimeoutInvalidAndLateSamplesNeverBecomeClicks() throws {
        var escaped = try StrokeCapture(origin: sample(0, 0, 0), timeoutReason: "timeout")
        escaped.cancel("escape")
        XCTAssertEqual(escaped.move(sample(100, 0, 1)), .cancelled("escape"))
        XCTAssertEqual(escaped.release(sample(100, 0, 2)), .cancelled("escape"))
        var timed = try StrokeCapture(
            origin: sample(0, 0, 0), maximumDuration: 10, timeoutReason: "timeout")
        XCTAssertEqual(timed.advanceClock(to: 10), .cancelled("timeout"))
        XCTAssertEqual(timed.release(sample(0, 0, 11)), .cancelled("timeout"))
        var invalid = try StrokeCapture(origin: sample(0, 0, 2), timeoutReason: "timeout")
        XCTAssertEqual(invalid.release(sample(18, 0, 1)), .rejected(.outOfOrderTimestamp))
        var nonfinite = try StrokeCapture(origin: sample(0, 0, 0), timeoutReason: "timeout")
        XCTAssertEqual(nonfinite.release(sample(.infinity, 0, 1)), .rejected(.invalidCoordinates))
    }
    func testBindingCandidateDisabledUnavailableAndUnboundStayDistinct() {
        let table = BindingTable(
            defaults: ["R": GestureBindingValue("next"), "L": GestureBindingValue("back")],
            overrides: ["R": GestureBindingValue("next", disabled: true)])
        XCTAssertEqual(table.resolve("R") { _ -> String? in nil }, .disabled)
        XCTAssertEqual(table.resolve("L") { _ -> String? in nil }, .candidate("back"))
        XCTAssertEqual(table.resolve("L") { _ in "busy" }, .unavailable("busy"))
        XCTAssertEqual(table.resolve("D") { _ -> String? in nil }, .unbound)
        XCTAssertEqual(table.effectiveBindings, ["L": "back"])
    }
}
