import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// File > Export Listing… and Print Listing…. The listing is what the pane shows: its visible
/// columns, current sort and current filter. The engine renders; this file collects the entries,
/// asks for options and writes the result.
@MainActor
extension BrowserViewController {
    struct ExportOptions: Sendable {
        var format: ListingExport.Format = .csv
        var selectionOnly = false
        var includeHidden = false
        var recursive = false
    }

    func exportListing() {
        guard let pane = activePane, let window = view.window else {
            NSSound.beep()
            return
        }
        guard listingExportTask == nil else { return NSSound.beep() }
        let context = pane.exportContext()
        let panel = NSSavePanel()
        panel.title = L("export.title", "Export Listing")
        panel.prompt = L("export.prompt", "Export")
        panel.canCreateDirectories = true
        let accessory = ExportListingAccessory(
            hasSelection: !context.selected.isEmpty, canWiden: context.isLocal,
            hiddenShown: context.hiddenShown)
        panel.accessoryView = accessory
        let baseName = context.title.isEmpty ? "Listing" : context.title
        func syncFormat() {
            let ext = accessory.options.format.fileExtension
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
            panel.nameFieldStringValue = baseName + "." + ext
        }
        accessory.onFormatChange = syncFormat
        syncFormat()
        panel.beginSheetModal(for: window) { [weak self, weak pane] response in
            guard response == .OK, let url = panel.url, let self, let pane else { return }
            self.runListingExport(
                context: context, options: accessory.options, to: url, pane: pane)
        }
    }

    /// Stop a running recursive export.
    func cancelListingExport() {
        listingExportTask?.cancel()
    }

    private func runListingExport(
        context: PaneController.ExportContext, options: ExportOptions, to url: URL,
        pane: PaneController
    ) {
        pane.flashStatus(L("export.working", "Exporting listing…"))
        let captions = Self.exportCaptions()
        let accent = ThemeManager.shared.accent.usingColorSpace(.sRGB)
        let accentHex = accent.map {
            String(
                format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255),
                Int($0.blueComponent * 255))
        }
        listingExportTask = Task { [weak self] in
            let flag = ExportCancelFlag()
            let result: Result<(Int, Bool), Error> = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    do {
                        let document = Self.buildDocument(context, options, flag: flag)
                        let text = ListingExport.render(
                            document, as: options.format, captions: captions, accentHex: accentHex)
                        try text.write(to: url, atomically: true, encoding: .utf8)
                        return .success((document.items.count, document.truncated))
                    } catch {
                        return .failure(error)
                    }
                }.value
            } onCancel: {
                flag.cancel()
            }
            guard let self else { return }
            self.listingExportTask = nil
            switch result {
            case .success(let (count, truncated)):
                if flag.isCancelled {
                    // A cancelled run still wrote what it had; say so rather than imply it is whole.
                    pane.flashStatus(
                        L("export.cancelled", "Export cancelled; the file is incomplete"),
                        isError: true)
                } else {
                    pane.flashStatus(
                        String(format: L("export.done", "Exported %d items"), count)
                            + (truncated ? " " + L("export.truncated", "(list cut short)") : ""))
                }
            case .failure(let error):
                pane.flashStatus(error.localizedDescription, isError: true)
            }
        }
    }

    /// Collect the items for an export. Runs off the main thread.
    nonisolated static func buildDocument(
        _ context: PaneController.ExportContext, _ options: ExportOptions, flag: ExportCancelFlag
    ) -> ListingExport.Document {
        let selected: Set<String>? = options.selectionOnly ? context.selected : nil
        var items: [ListingItem]
        var truncated = false
        if options.recursive, context.isLocal, let root = context.url {
            let walk = ListingExport.collectRecursively(
                root: root, includeHidden: options.includeHidden, topLevelNames: selected,
                isCancelled: { flag.isCancelled })
            // The pane's live filter applies to the flat list too.
            items = walk.items.filter { context.filter.isEmpty || context.filter.matches($0.entry) }
            truncated = walk.truncated
        } else {
            var entries = context.entries
            if options.includeHidden, !context.hiddenShown, context.isLocal, let root = context.url
            {
                let hidden =
                    ((try? BulkEnumerator().entries(of: root, includingHidden: true)) ?? [])
                    .filter {
                        $0.isHidden && (context.filter.isEmpty || context.filter.matches($0))
                    }
                entries = context.format.sorted(entries + hidden)
            }
            items = ListingExport.items(
                from: entries, selected: selected, includeHidden: options.includeHidden)
        }
        let fields = ListingField.fields(
            forColumnIDs: context.columnIDs, recursive: options.recursive)
        return ListingExport.Document(
            title: context.url?.path ?? context.title, fields: fields, items: items,
            truncated: truncated)
    }

    nonisolated static func exportCaptions() -> ListingExport.Captions {
        var captions = ListingExport.Captions()
        captions.name = L("list.columnName", "Name")
        captions.path = L("export.columnPath", "Path")
        captions.kind = L("list.columnKind", "Kind")
        captions.sizeBytes = L("export.columnSizeBytes", "Size (bytes)")
        captions.size = L("list.columnSize", "Size")
        captions.modified = L("list.columnDate", "Date Modified")
        captions.created = L("list.columnDateCreated", "Date Created")
        captions.accessed = L("list.columnDateAccessed", "Date Last Opened")
        return captions
    }

    /// File > Print Listing…: the shown listing as monospaced text under a header with the folder
    /// and the date, through the standard print panel.
    func printListing() {
        guard let pane = activePane, let window = view.window else {
            NSSound.beep()
            return
        }
        let context = pane.exportContext()
        let options = ExportOptions(
            format: .text, selectionOnly: false, includeHidden: context.hiddenShown,
            recursive: false)
        let document = Self.buildDocument(context, options, flag: ExportCancelFlag())
        let body = ListingExport.render(
            document, as: .text, captions: Self.exportCaptions())
        let stamp = DateFormatter.localizedString(
            from: Date(), dateStyle: .medium, timeStyle: .short)
        let text = "\(document.title)\n\(stamp)\n\n" + body

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 8, weight: .regular)
        textView.textColor = .black
        textView.backgroundColor = .white
        textView.string = text
        textView.textContainer?.widthTracksTextView = true
        textView.sizeToFit()
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.jobTitle = document.title
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// A flag the detached export worker polls, set from the task's cancellation handler.
final class ExportCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// The save panel's accessory: format and the three scope options.
@MainActor
final class ExportListingAccessory: NSView {
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectionBox = NSButton(
        checkboxWithTitle: L("export.selectionOnly", "Selected items only"), target: nil,
        action: nil)
    private let hiddenBox = NSButton(
        checkboxWithTitle: L("export.includeHidden", "Include hidden files"), target: nil,
        action: nil)
    private let recurseBox = NSButton(
        checkboxWithTitle: L("export.recurse", "Include subfolders"), target: nil, action: nil)
    var onFormatChange: (() -> Void)?

    private static let formats: [(ListingExport.Format, String)] = [
        (.csv, L("export.formatCSV", "CSV (comma-separated)")),
        (.tsv, L("export.formatTSV", "TSV (tab-separated)")),
        (.text, L("export.formatText", "Plain text (aligned columns)")),
        (.html, L("export.formatHTML", "HTML table")),
    ]

    var options: BrowserViewController.ExportOptions {
        BrowserViewController.ExportOptions(
            format: Self.formats[max(0, formatPopup.indexOfSelectedItem)].0,
            selectionOnly: selectionBox.state == .on && selectionBox.isEnabled,
            includeHidden: hiddenBox.state == .on,
            recursive: recurseBox.state == .on && recurseBox.isEnabled)
    }

    init(hasSelection: Bool, canWiden: Bool, hiddenShown: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
        formatPopup.addItems(withTitles: Self.formats.map(\.1))
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        let label = NSTextField(labelWithString: L("export.formatLabel", "Format"))
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let formatRow = NSStackView(views: [label, formatPopup])
        formatRow.spacing = 8
        selectionBox.isEnabled = hasSelection
        hiddenBox.isEnabled = canWiden
        hiddenBox.state = hiddenShown ? .on : .off
        recurseBox.isEnabled = canWiden
        let stack = NSStackView(views: [formatRow, selectionBox, hiddenBox, recurseBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func formatChanged() { onFormatChange?() }
}

#if DEBUG
extension ExportListingAccessory {
    /// Render the save panel's accessory to a PNG (PATHEM_EXPORT_SHOT) with sample state.
    static func debugRender(to path: String, appearance: NSAppearance?) {
        let view = ExportListingAccessory(hasSelection: true, canWiden: true, hiddenShown: false)
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("EXPORT SHOT: \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }
}
#endif
