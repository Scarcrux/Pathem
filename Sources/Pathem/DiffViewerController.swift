import AppKit
import PathemEngine

/// A side-by-side text diff of two files: a two-column table with per-line coloring
/// (removed lines tinted red on the left, added lines green on the right). A reusable
/// panel; the diff is computed off-main. Non-text or unreadable files show a note.
@MainActor
final class DiffViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let header = NSTextField(labelWithString: "")
    private var lines: [TextDiff.Line] = []
    private let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.title = L("diff.title", "Compare")
        panel.isReleasedWhenClosed = false
        build()
    }

    func present(left: URL, right: URL, over window: NSWindow?) {
        panel.title = String(
            format: L("diff.titleFor", "%@  ↔  %@"), left.lastPathComponent, right.lastPathComponent)
        header.stringValue = L("diff.computing", "Comparing…")
        lines = []
        table.reloadData()
        if !panel.isVisible { panel.centerOverMainWindow() }
        panel.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            let outcome = await Task.detached { () -> TextDiff.Result? in
                guard let a = Self.readText(left), let b = Self.readText(right) else { return nil }
                return TextDiff.diff(a, b)
            }.value
            guard let outcome else {
                self.header.stringValue = L("diff.notText", "One or both files are not readable text.")
                return
            }
            self.lines = outcome.lines
            self.header.stringValue =
                String(format: L("diff.stats", "%d added, %d removed"), outcome.added, outcome.removed)
                + (outcome.truncated ? L("diff.truncated", " (truncated)") : "")
            self.table.reloadData()
        }
    }

    nonisolated private static func readText(_ url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private func build() {
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        for id in ["left", "right"] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = 420
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.rowHeight = 16
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        let root = NSStackView(views: [header, scroll])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            ])
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < lines.count else { return nil }
        let line = lines[row]
        let isLeft = tableColumn.identifier.rawValue == "left"
        let text = isLeft ? line.left : line.right
        let number = isLeft ? line.leftNumber : line.rightNumber
        let tint: NSColor
        switch line.kind {
        case .equal: tint = .clear
        case .delete: tint = isLeft ? NSColor.systemRed.withAlphaComponent(0.16) : .clear
        case .insert: tint = isLeft ? .clear : NSColor.systemGreen.withAlphaComponent(0.16)
        }

        let id = NSUserInterfaceItemIdentifier("diffcell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DiffCell) ?? DiffCell(id: id, font: mono)
        cell.configure(number: number, text: text ?? "", tint: tint)
        return cell
    }
}

/// One diff cell: a dim line number and monospaced text over a tint color.
private final class DiffCell: NSTableCellView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier, font: NSFont) {
        super.init(frame: .zero)
        identifier = id
        wantsLayer = true
        numberLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        numberLabel.textColor = .tertiaryLabelColor
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = font
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)
        addSubview(textLabel)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            numberLabel.widthAnchor.constraint(equalToConstant: 34),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(number: Int?, text: String, tint: NSColor) {
        numberLabel.stringValue = number.map(String.init) ?? ""
        textLabel.stringValue = text
        layer?.backgroundColor = tint.cgColor
    }
}
