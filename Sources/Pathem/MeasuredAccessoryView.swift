import AppKit

/// AppKit sizes alert/save-panel accessories from their frame, not their fitting size.
/// Keep a frame-owned outer view while Auto Layout measures the bounded inner content.
@MainActor
final class MeasuredAccessoryView: NSView {
    private let content: NSView
    private let contentWidth: NSLayoutConstraint
    private var contentHeight: NSLayoutConstraint?
    private var measuredSize = NSSize.zero
    var onSizeChanged: (() -> Void)?

    init(content: NSView, width: CGFloat) {
        self.content = content
        content.translatesAutoresizingMaskIntoConstraints = false
        contentWidth = content.widthAnchor.constraint(equalToConstant: width)
        super.init(frame: .zero)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            contentWidth,
        ])
        resizeToFit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { measuredSize }

    /// Controls report different metrics once they are in a window: a text field's fitting
    /// height is 21 pt detached and 24 pt inside an alert on macOS 27.2. A size measured at
    /// construction is therefore 3 pt short, which pushed the last control out of the
    /// reserved area until some later event re-measured. Measure again on attach, so the
    /// first frame is right, and once more after the current pass in case metrics settle
    /// only when the window's own layout has finished.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        #if DEBUG
        if LayoutMatrixGeometry.injection == "accessory-short" {
            LayoutMatrixGeometry.traceInjection(
                "accessory-short", "skipping attached remeasurement")
            return
        }
        #endif
        resizeToFit()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.resizeToFit()
        }
    }

    func setWidth(_ width: CGFloat) {
        contentWidth.constant = width
        resizeToFit()
    }

    func resizeToFit() {
        contentHeight?.isActive = false
        let size = NSSize(
            width: contentWidth.constant, height: max(1, ceil(content.fittingSize.height)))
        contentHeight = content.heightAnchor.constraint(equalToConstant: size.height)
        contentHeight?.isActive = true
        let changed = measuredSize != size
        measuredSize = size
        setFrameSize(size)
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
        if changed { onSizeChanged?() }
    }
}
