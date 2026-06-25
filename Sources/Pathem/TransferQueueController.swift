import AppKit
import PathemEngine

/// A persistent, non-modal transfer manager: queued/running/finished jobs in a list you
/// can reorder (drag pending rows to change what runs next), cancel individually or all
/// at once, and clear when done. Jobs run one at a time; cancelling a running job
/// terminates its out-of-process tool via Task cancellation. Drop-in for the old modal
/// sheet: `run(items:title:over:completion:)` keeps the same shape.
@MainActor
final class TransferQueueController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    struct Item {
        let name: String
        let run: () async throws -> Void
    }

    private enum State { case queued, running, done, failed, cancelled }

    private final class Job {
        let id = UUID()
        let name: String
        let batch: UUID
        let run: () async throws -> Void
        var state: State = .queued
        init(name: String, batch: UUID, run: @escaping () async throws -> Void) {
            self.name = name
            self.batch = batch
            self.run = run
        }
    }

    private struct Batch {
        var remaining: Int
        var failures: [(String, Error)] = []
        var cancelled = false
        let completion: ([(String, Error)], Bool) -> Void
    }

    private let window: NSWindow
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var jobs: [Job] = []
    private var batches: [UUID: Batch] = [:]
    private var currentJob: Job?
    private var currentTask: Task<Void, Never>?
    private static let dragType = NSPasteboard.PasteboardType("com.scarcrux.pathem.transferRow")

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        super.init()
        window.title = L("queue.title", "Transfers")
        window.delegate = self
        window.isReleasedWhenClosed = false
        build()
    }

    /// Enqueue a batch of transfers, show the window, and call `completion` (failures,
    /// cancelled) when this batch finishes. `window` is accepted for call-site parity.
    func run(
        _ items: [Item], title: String, over window: NSWindow,
        completion: @escaping ([(String, Error)], Bool) -> Void
    ) {
        guard !items.isEmpty else {
            completion([], false)
            return
        }
        let batchID = UUID()
        batches[batchID] = Batch(remaining: items.count, completion: completion)
        jobs.append(contentsOf: items.map { Job(name: $0.name, batch: batchID, run: $0.run) })
        statusLabel.stringValue = title
        table.reloadData()
        if !self.window.isVisible { self.window.center() }
        self.window.makeKeyAndOrderFront(nil)
        pump()
    }

    /// Bring the transfer manager forward (Tools menu).
    func showWindow() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        updateStatus()
    }

    // MARK: Processing

    private func pump() {
        guard currentJob == nil else { return }  // one at a time
        guard let next = jobs.first(where: { $0.state == .queued }) else {
            updateStatus()
            return
        }
        next.state = .running
        currentJob = next
        table.reloadData()
        updateStatus()
        currentTask = Task { @MainActor in
            var failure: Error?
            do { try await next.run() } catch { failure = error }
            self.finish(next, failure: Task.isCancelled ? nil : failure, cancelled: Task.isCancelled)
        }
    }

    private func finish(_ job: Job, failure: Error?, cancelled: Bool) {
        job.state = cancelled ? .cancelled : (failure == nil ? .done : .failed)
        if var batch = batches[job.batch] {
            batch.remaining -= 1
            if let failure { batch.failures.append((job.name, failure)) }
            if cancelled { batch.cancelled = true }
            if batch.remaining <= 0 {
                batch.completion(batch.failures, batch.cancelled)
                batches[job.batch] = nil
            } else {
                batches[job.batch] = batch
            }
        }
        currentJob = nil
        currentTask = nil
        table.reloadData()
        pump()
    }

    /// Cancel a queued or running job.
    private func cancel(_ job: Job) {
        switch job.state {
        case .queued:
            finish(job, failure: nil, cancelled: true)
        case .running:
            currentTask?.cancel()  // finish() runs from the task's cancellation path
        default:
            break
        }
    }

    @objc private func cancelSelected() {
        let row = table.selectedRow
        guard row >= 0, row < jobs.count else { return }
        cancel(jobs[row])
    }

    @objc private func cancelAll() {
        for job in jobs where job.state == .queued { finish(job, failure: nil, cancelled: true) }
        currentTask?.cancel()
    }

    @objc private func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
        table.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        let active = jobs.filter { $0.state == .queued || $0.state == .running }.count
        statusLabel.stringValue =
            active == 0
            ? L("queue.idle", "No active transfers")
            : String(format: L("queue.active", "%d in progress"), active)
    }

    func windowWillClose(_ notification: Notification) {}  // keep jobs; window just hides

    // MARK: UI

    private func build() {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        updateStatus()

        let cancelButton = NSButton(title: L("queue.cancel", "Cancel"), target: self, action: #selector(cancelSelected))
        let cancelAllButton = NSButton(title: L("queue.cancelAll", "Cancel All"), target: self, action: #selector(cancelAll))
        let clearButton = NSButton(title: L("queue.clear", "Clear Finished"), target: self, action: #selector(clearFinished))
        for button in [cancelButton, cancelAllButton, clearButton] { button.bezelStyle = .rounded }

        for (id, title, width) in [
            ("status", L("queue.statusColumn", "Status"), CGFloat(120)),
            ("name", L("queue.nameColumn", "Item"), 340),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.registerForDraggedTypes([Self.dragType])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let buttons = NSStackView(views: [statusLabel, NSView(), cancelButton, cancelAllButton, clearButton])
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

    func numberOfRows(in tableView: NSTableView) -> Int { jobs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < jobs.count else { return nil }
        let job = jobs[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
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
        if tableColumn.identifier.rawValue == "name" {
            cell.textField?.stringValue = job.name
            cell.textField?.textColor = .labelColor
        } else {
            cell.textField?.stringValue = statusText(job.state)
            cell.textField?.textColor = statusColor(job.state)
        }
        return cell
    }

    private func statusText(_ state: State) -> String {
        switch state {
        case .queued: return L("queue.queued", "Queued")
        case .running: return L("queue.running", "Transferring…")
        case .done: return L("queue.done", "Done")
        case .failed: return L("queue.failed", "Failed")
        case .cancelled: return L("queue.cancelled", "Cancelled")
        }
    }

    private func statusColor(_ state: State) -> NSColor {
        switch state {
        case .running: return .controlAccentColor
        case .done: return .systemGreen
        case .failed: return .systemRed
        case .cancelled, .queued: return .secondaryLabelColor
        }
    }

    // MARK: Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < jobs.count, jobs[row].state == .queued else { return nil }  // only reorder pending
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let string = info.draggingPasteboard.string(forType: Self.dragType),
            let from = Int(string), from < jobs.count
        else { return false }
        let job = jobs.remove(at: from)
        let target = from < row ? row - 1 : row
        jobs.insert(job, at: min(max(target, 0), jobs.count))
        table.reloadData()
        return true
    }
}
