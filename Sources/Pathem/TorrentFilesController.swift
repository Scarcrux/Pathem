import AppKit
import TorrentKit

/// A per-torrent file picker: a checkbox list of the torrent's files, so the user can download
/// only some of a multi-file torrent. Presented from the Torrents panel; applies the selection
/// back through the daemon.
@MainActor
final class TorrentFilesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private var files: [TorrentSession.FileInfo] = []
    private var checked: [Bool] = []
    private var onApply: (([Int]) -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = L("torrents.files.title", "Select Files")
        window.isReleasedWhenClosed = false
        build()
    }

    func present(name: String, files: [TorrentSession.FileInfo], over parent: NSWindow?, apply: @escaping ([Int]) -> Void) {
        self.files = files
        self.checked = files.map(\.wanted)
        self.onApply = apply
        window.title = String(format: L("torrents.files.titleFor", "Files in “%@”"), name)
        table.reloadData()
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func build() {
        let checkCol = NSTableColumn(identifier: .init("check"))
        checkCol.title = ""
        checkCol.width = 24
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L("torrents.files.name", "File")
        nameCol.width = 360
        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L("torrents.files.size", "Size")
        sizeCol.width = 90
        table.addTableColumn(checkCol)
        table.addTableColumn(nameCol)
        table.addTableColumn(sizeCol)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let selectAll = NSButton(title: L("torrents.files.all", "Select All"), target: self, action: #selector(selectAll(_:)))
        selectAll.bezelStyle = .rounded
        let selectNone = NSButton(title: L("torrents.files.none", "Deselect All"), target: self, action: #selector(deselectAll))
        selectNone.bezelStyle = .rounded
        let apply = NSButton(title: L("torrents.files.apply", "Apply"), target: self, action: #selector(applyTapped))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [selectAll, selectNone, NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
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

    @objc private func selectAll(_ sender: Any?) { checked = Array(repeating: true, count: files.count); table.reloadData() }
    @objc private func deselectAll() { checked = Array(repeating: false, count: files.count); table.reloadData() }

    @objc private func applyTapped() {
        // Refuse an empty selection (nothing to download); treat it as "select all" instead.
        var wanted = (0..<files.count).filter { checked[$0] }
        if wanted.isEmpty { wanted = Array(0..<files.count) }
        onApply?(wanted)
        dismiss()
    }

    @objc private func cancelTapped() { dismiss() }

    private func dismiss() {
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        let row = sender.tag
        if row >= 0 && row < checked.count { checked[row] = sender.state == .on }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < files.count else { return nil }
        let file = files[row]
        switch tableColumn.identifier.rawValue {
        case "check":
            let id = NSUserInterfaceItemIdentifier("check")
            let button = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton) ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
                b.identifier = id
                return b
            }()
            button.tag = row
            button.state = checked[row] ? .on : .off
            return button
        default:
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let f = NSTextField(labelWithString: "")
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
            if tableColumn.identifier.rawValue == "size" {
                cell.textField?.stringValue = Self.size.string(fromByteCount: file.length)
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            } else {
                cell.textField?.stringValue = file.path
                cell.textField?.font = .systemFont(ofSize: 12)
            }
            return cell
        }
    }

    private static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
