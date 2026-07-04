import AppKit
import PathemEngine

/// A read-only viewer for what's inside an archive (a peek without extracting), with an
/// Extract All action. Full mount-and-navigate is a later step; this lists the entries.
@MainActor
final class ArchiveContentsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    var debugWindowNumber: Int { panel.windowNumber }
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var entries: [String] = []
    private var onExtractAll: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(over window: NSWindow, archiveName: String, entries: [String], onExtractAll: @escaping () -> Void) {
        self.entries = entries.sorted()
        self.onExtractAll = onExtractAll
        panel.title = archiveName
        countLabel.stringValue = String(format: L("archive.count", "%d items"), entries.count)
        table.reloadData()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("path"))
        column.title = L("archive.contents", "Contents")
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let extractAll = NSButton(
            title: L("archive.extractAll", "Extract All…"), target: self, action: #selector(extractAllTapped))
        extractAll.bezelStyle = .rounded
        let close = NSButton(title: L("common.close", "Close"), target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        extractAll.keyEquivalent = "\r"  // default action, highlighted
        let buttons = NSStackView(views: [countLabel, NSView(), close, extractAll])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            ])
        }
    }

    @objc private func extractAllTapped() {
        onExtractAll?()
        panel.orderOut(nil)
    }
    @objc private func closeTapped() { panel.orderOut(nil) }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let f = NSTextField(labelWithString: "")
                f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                f.lineBreakMode = .byTruncatingMiddle
                f.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(f)
                c.textField = f
                NSLayoutConstraint.activate([
                    f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        if row < entries.count {
            let path = entries[row]
            cell.textField?.stringValue = path
            cell.textField?.textColor = path.hasSuffix("/") ? .secondaryLabelColor : .labelColor
        }
        return cell
    }
}
