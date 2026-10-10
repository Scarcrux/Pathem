import AppKit
import GestureRecording
import PathemEngine

/// Renders a gesture stroke ("RD") as arrows ("→↓").
enum GestureFormat {
    private static let arrows: [Character: String] = ["R": "→", "L": "←", "U": "↑", "D": "↓"]
    static func display(_ stroke: String) -> String {
        stroke.map { arrows[$0] ?? String($0) }.joined()
    }
}

/// Shared recording canvas. Pathem retains its localized labels, saved string
/// format, accent and empty-click clear behavior; recording never runs an action.
@MainActor
final class GestureRecorderView: StrokeRecordingView {
    var onRecord: ((String) -> Void)?
    var onClear: (() -> Void)?
    var stroke: String = "" { didSet { updateLabel() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        overflowPolicy = .prefix
        hintFont = .systemFont(ofSize: 15)
        onStroke = { [weak self] directions in self?.onRecord?(directions.map(\.letter).joined()) }
        onEmpty = { [weak self] in self?.onClear?() }
        accentColor = ThemeManager.shared.accent
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draw(_ dirtyRect: NSRect) {
        accentColor = ThemeManager.shared.accent
        super.draw(dirtyRect)
    }
    private func updateLabel() {
        idleText =
            stroke.isEmpty
            ? L("gestures.recordHint", "Drag here to record a gesture")
            : GestureFormat.display(stroke)
    }
}
