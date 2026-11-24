import AppKit

/// A floating pill of quick-action buttons that appears over the panes when items are
/// selected (like Windows Explorer's selection command bar). Each button runs an existing
/// command by id; the bar hides itself when nothing is selected.
@MainActor
final class QuickActionsBar: NSView {
    /// Perform the command with this id (wired to the browser's command table).
    var onAction: ((String) -> Void)?
    /// Pop up the "Open With" apps menu, anchored to the given button.
    var onOpenWith: ((NSView) -> Void)?
    /// After a Copy/Cut, offer a follow-up paste menu anchored to the given button.
    var onCopiedShowPaste: ((NSView) -> Void)?

    private let blur = NSVisualEffectView()
    private let stack = NSStackView()
    /// (command id, button, whether it needs exactly one selected item).
    private var buttons: [(id: String, button: NSButton, needsSingle: Bool, viewableOnly: Bool)] =
        []

    /// id, SF Symbol, tooltip, needs a single selection, only for a viewable file (PDF/image).
    private static let actions: [(String, String, String, Bool, Bool)] = [
        ("files.open", "arrow.up.forward.app", L("quick.open", "Open"), false, false),
        (
            "files.openInThisPane", "rectangle.lefthalf.inset.filled",
            L("bvc.cmd.openInThisPane", "Open in This Pane"), true, true
        ),
        (
            "files.openInOtherPane", "rectangle.righthalf.inset.filled",
            L("bvc.cmd.openInOtherPane", "Open in Other Pane"), true, true
        ),
        ("files.openWith", "square.grid.2x2", L("quick.openWith", "Open With"), false, false),
        ("files.rename", "pencil", L("quick.rename", "Rename"), true, false),
        ("files.copy", "doc.on.doc", L("quick.copy", "Copy"), false, false),
        ("files.compress", "archivebox", L("quick.compress", "Compress"), false, false),
        ("files.getInfo", "info.circle", L("quick.getInfo", "Get Info"), false, false),
        ("files.trash", "trash", L("quick.trash", "Move to Trash"), false, false),
    ]

    init() {
        super.init(frame: .zero)
        build()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.applyTint() }
        applyTint()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        // A soft shadow on the (unclipped) container; the blurred pill inside is clipped-rounded.
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 11
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)

        for (index, action) in Self.actions.enumerated() {
            let (id, symbol, tip, single, viewableOnly) = action
            if index == Self.actions.count - 1, !buttons.isEmpty {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
                stack.addArrangedSubview(separator)  // set off destructive Trash
            }
            let button = NSButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = tip
            button.target = self
            button.action = #selector(tapped(_:))
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(button)
            buttons.append((id, button, single, viewableOnly))
        }

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])
    }

    private func applyTint() {
        for (id, button, _, _) in buttons {
            button.contentTintColor = id == "files.trash" ? .systemRed : ThemeManager.shared.accent
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: 11, cornerHeight: 11, transform: nil)
    }

    /// Show/hide and enable buttons for the current selection.
    /// Whether the View-in-pane (viewable-only) buttons are currently shown (smoke guard).
    var debugViewButtonsShown: Bool { buttons.contains { $0.viewableOnly && !$0.button.isHidden } }

    func update(selectionCount: Int, isViewable: Bool) {
        isHidden = selectionCount == 0
        for (_, button, needsSingle, viewableOnly) in buttons {
            if viewableOnly {
                // The View-in-pane buttons appear only for a single PDF/image.
                button.isHidden = !(selectionCount == 1 && isViewable)
            } else {
                button.isHidden = false
                button.isEnabled = needsSingle ? selectionCount == 1 : selectionCount >= 1
            }
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard sender.tag < buttons.count else { return }
        let id = buttons[sender.tag].id
        if id == "files.openWith" {
            onOpenWith?(sender)  // opens a menu of apps rather than running a single command
        } else {
            onAction?(id)
            // A copy/cut has no visible result; immediately offer where to paste it.
            if id == "files.copy" || id == "files.cut" { onCopiedShowPaste?(sender) }
        }
    }
}
