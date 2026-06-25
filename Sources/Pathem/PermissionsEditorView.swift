import AppKit
import PathemEngine

/// An editable POSIX-permissions grid for Get Info: read/write/execute checkboxes for
/// owner/group/other plus an octal field. Each change applies chmod via the callback;
/// a failure (e.g. not the owner) reverts the control and beeps.
@MainActor
final class PermissionsEditorView: NSView {
    private var mode: UInt16  // last successfully-applied mode
    private let apply: (UInt16) -> Bool
    private var boxes: [[NSButton]] = []  // [owner, group, other] x [r, w, x]
    private let octalField = NSTextField()

    init(mode: UInt16, apply: @escaping (UInt16) -> Bool) {
        self.mode = mode
        self.apply = apply
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        func header(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 10, weight: .semibold)
            f.textColor = .secondaryLabelColor
            f.alignment = .center
            return f
        }
        func rowLabel(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            return f
        }
        let rows = [
            L("perms.owner", "Owner"), L("perms.group", "Group"), L("perms.other", "Other"),
        ]
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 2
        grid.columnSpacing = 6
        grid.addRow(with: [
            NSView(), header(L("perms.read", "R")), header(L("perms.write", "W")),
            header(L("perms.exec", "X")),
        ])
        for (r, name) in rows.enumerated() {
            var rowBoxes: [NSButton] = []
            for c in 0..<3 {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxToggled))
                box.tag = r * 3 + c
                rowBoxes.append(box)
            }
            boxes.append(rowBoxes)
            grid.addRow(with: [rowLabel(name)] + rowBoxes)
        }

        octalField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        octalField.alignment = .center
        octalField.target = self
        octalField.action = #selector(octalChanged)
        octalField.cell?.sendsActionOnEndEditing = true
        octalField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let octalLabel = rowLabel(L("perms.octal", "Octal"))
        let octalRow = NSStackView(views: [octalLabel, octalField])
        octalRow.orientation = .horizontal
        octalRow.spacing = 6

        let stack = NSStackView(views: [grid, octalRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Reflect `mode` in the checkboxes and the octal field.
    private func refresh() {
        for r in 0..<3 {
            let triplet = (Int(mode) >> ((2 - r) * 3)) & 0x7
            boxes[r][0].state = (triplet & 0x4) != 0 ? .on : .off
            boxes[r][1].state = (triplet & 0x2) != 0 ? .on : .off
            boxes[r][2].state = (triplet & 0x1) != 0 ? .on : .off
        }
        octalField.stringValue = String(mode & 0o777, radix: 8)
    }

    @objc private func boxToggled(_ sender: NSButton) {
        let r = sender.tag / 3, c = sender.tag % 3
        let bit = UInt16(0x4 >> c) << UInt16((2 - r) * 3)
        var candidate = mode
        if sender.state == .on { candidate |= bit } else { candidate &= ~bit }
        commit(candidate)
    }

    @objc private func octalChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(text, radix: 8), value <= 0o7777 else {
            refresh()  // reject garbage, restore the known-good value
            return
        }
        // Preserve the high bits (setuid/setgid/sticky) the user can't see in the grid.
        commit((mode & 0o7000) | (value & 0o777) | (value & 0o7000))
    }

    /// Apply a candidate mode; keep it only if chmod succeeds.
    private func commit(_ candidate: UInt16) {
        guard candidate != mode else { return }
        if apply(candidate) {
            mode = candidate
        } else {
            NSSound.beep()
        }
        refresh()
    }
}
