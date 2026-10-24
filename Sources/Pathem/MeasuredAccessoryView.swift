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
