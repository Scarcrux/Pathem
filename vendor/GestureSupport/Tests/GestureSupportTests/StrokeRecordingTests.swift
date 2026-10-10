#if canImport(AppKit)
import AppKit
import GestureRecording
import GestureSupport
import XCTest

final class StrokeRecordingTests: XCTestCase {
    @MainActor
    func testNativePreviewThenExactlyOneRecordingAndEscapeCancel() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let view = StrokeRecordingView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        window.contentView = view
        defer {
            view.cancelRecording()
            window.contentView = nil
        }
        view.allowedButtons = [1]
        var recorded: [[StrokeDirection]] = []
        var empty = 0
        view.onStroke = { recorded.append($0) }
        view.onEmpty = { empty += 1 }
        view.preview = { $0 == [.right] ? "Next tab · practice only" : "Draw · Escape cancels" }
        let start = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ x: Double, _ time: Double) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: 40), modifierFlags: [],
                    timestamp: start + time, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 0))
        }
        view.mouseDown(with: try event(.leftMouseDown, 20, 0))
        view.mouseDragged(with: try event(.leftMouseDragged, 60, 0.05))
        view.mouseUp(with: try event(.leftMouseUp, 60, 0.06))
        XCTAssertFalse(view.isRecording)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertEqual(empty, 0)
        view.rightMouseDown(with: try event(.rightMouseDown, 20, 0))
        view.rightMouseDragged(with: try event(.rightMouseDragged, 60, 0.1))
        XCTAssertEqual(view.hint, "Next tab · practice only")
        XCTAssertTrue(recorded.isEmpty, "Preview cannot execute or record before release")
        view.rightMouseUp(with: try event(.rightMouseUp, 60, 0.2))
        view.rightMouseUp(with: try event(.rightMouseUp, 60, 0.3))
        XCTAssertEqual(recorded, [[.right]])
        XCTAssertEqual(view.capturedPointCount, 0)
        view.rightMouseDown(with: try event(.rightMouseDown, 20, 0.4))
        view.rightMouseDragged(with: try event(.rightMouseDragged, 60, 0.5))
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: start + 0.6,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(view.handleCancellationKey(escape))
        view.rightMouseUp(with: try event(.rightMouseUp, 60, 0.7))
        XCTAssertEqual(recorded, [[.right]])
        XCTAssertEqual(empty, 0)
        XCTAssertFalse(view.isRecording)
    }
    @MainActor
    func testNativeWindowLifecycleCancellationAndDenseCaptureBound() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let view = StrokeRecordingView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        window.contentView = view
        defer {
            view.cancelRecording()
            window.contentView = nil
        }
        var count = 0
        view.onStroke = { _ in count += 1 }
        view.onEmpty = { count += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ i: Int) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: Double(i), y: 40), modifierFlags: [],
                    timestamp: start + Double(i) / 1000, windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 0))
        }
        view.mouseDown(with: try event(.leftMouseDown, 0))
        for i in 1...1000 { view.mouseDragged(with: try event(.leftMouseDragged, i)) }
        XCTAssertEqual(view.capturedPointCount, 256)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        view.mouseUp(with: try event(.leftMouseUp, 1001))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(view.capturedPointCount, 0)
        view.mouseDown(with: try event(.leftMouseDown, 0))
        view.removeFromSuperview()
        XCTAssertFalse(view.isRecording)
    }
}
#endif
