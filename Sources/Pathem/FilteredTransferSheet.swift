import AppKit
import PathemEngine

/// The "Copy / Move / Trash Matching…" sheet: filter fields, a live preview (count, size and the
/// first few matches) and the run button. All matching is `FileFilterSpec` in the engine; the walk
/// runs off the main thread and is cancelled whenever the fields change again.
@MainActor
final class FilteredTransferSheet: NSObject, NSTextFieldDelegate {
    enum Action {
        case copy, move, trash

        var title: String {
            switch self {
            case .copy: return L("filtered.copyTitle", "Copy Matching Files")
            case .move: return L("filtered.moveTitle", "Move Matching Files")
            case .trash: return L("filtered.trashTitle", "Move Matching Files to the Trash")
            }
        }
        var runTitle: String {
            switch self {
            case .copy: return L("filtered.copyRun", "Copy")
            case .move: return L("filtered.moveRun", "Move")
            case .trash: return L("filtered.trashRun", "Move to Trash")
            }
        }
    }

    /// A cancellation flag the background walk can poll.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
        styleMask: [.titled], backing: .buffered, defer: true)
    private let include = NSTextField()
    private let exclude = NSTextField()
    private var kindBoxes: [(FileFilter.Kind, NSButton)] = []
    private let minSize = NSTextField()
    private let maxSize = NSTextField()
    private let minUnit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maxUnit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let afterBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let beforeBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let afterDate = NSDatePicker()
    private let beforeDate = NSDatePicker()
    private let recurseBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let structureBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hiddenBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let presetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let summary = NSTextField(labelWithString: "")
    private let list = NSTextView()
    private let spinner = NSProgressIndicator()
    private let runButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)

    private var action: Action = .copy
    private var sources: [URL] = []
    private var presetsStore = FileFilterPresets()
    private var presetsURL: URL?
    private var onRun: ((FileFilterSpec, FileFilterEnumerator.Result) -> Void)?
    private var previewFlag: CancelFlag?
    private var previewDelay: DispatchWorkItem?
    private var lastResult: FileFilterEnumerator.Result?
    private var host: NSWindow?
    private static let units: [(String, Int64)] = [
        ("KB", 1_000), ("MB", 1_000_000), ("GB", 1_000_000_000),
    ]

    override init() {
        super.init()
        build()
    }

    // MARK: Presenting

    func present(
        over window: NSWindow, action: Action, sources: [URL], destinationName: String?,
        presetsURL: URL?,
        onRun: @escaping (FileFilterSpec, FileFilterEnumerator.Result) -> Void
    ) {
        self.action = action
        self.sources = sources
        self.presetsURL = presetsURL
        self.onRun = onRun
        host = window
        panel.appearance = window.effectiveAppearance
        presetsStore =
            ConfigStore.load(FileFilterPresets.self, from: presetsURL) ?? FileFilterPresets()
        titleLabel.stringValue = action.title
        var detail = String(
            format: sources.count == 1
                ? L("filtered.fromOne", "From 1 selected item")
                : L("filtered.fromMany", "From %d selected items"),
            sources.count)
        if let destinationName {
            detail += " " + String(format: L("filtered.toFolder", "to “%@”"), destinationName)
        }
        detailLabel.stringValue = detail
        runButton.title = action.runTitle
        structureBox.isHidden = action == .trash
        apply(presetsStore.last ?? FileFilterSpec(recurse: true, keepStructure: true))
        rebuildPresetMenu()
        window.beginSheet(panel)
        panel.makeFirstResponder(include)
        schedulePreview(immediately: true)
    }

    private func finish(_ code: NSApplication.ModalResponse) {
        previewFlag?.cancel()
        previewDelay?.cancel()
        host?.endSheet(panel, returnCode: code)
        panel.orderOut(nil)
    }

    // MARK: Spec <-> controls

    private func currentSpec() -> FileFilterSpec {
        var spec = FileFilterSpec()
        spec.includePatterns = FileFilterSpec.splitPatterns(include.stringValue)
        spec.excludePatterns = FileFilterSpec.splitPatterns(exclude.stringValue)
        spec.kinds = Set(kindBoxes.filter { $0.1.state == .on }.map(\.0))
        spec.minBytes = bytes(minSize, minUnit)
        spec.maxBytes = bytes(maxSize, maxUnit)
        if afterBox.state == .on {
            spec.modifiedAfter = Calendar.current.startOfDay(for: afterDate.dateValue)
        }
        if beforeBox.state == .on {
            // Through the end of the chosen day.
            spec.modifiedBefore = Calendar.current.date(
                byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: beforeDate.dateValue)
            )?
            .addingTimeInterval(-1)
        }
        spec.recurse = recurseBox.state == .on
        spec.keepStructure = structureBox.state == .on
        spec.includeHidden = hiddenBox.state == .on
        return spec
    }

    private func bytes(_ field: NSTextField, _ unit: NSPopUpButton) -> Int64? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number >= 0
        else { return nil }
        return Int64(number * Double(Self.units[max(0, unit.indexOfSelectedItem)].1))
    }

    private func apply(_ spec: FileFilterSpec) {
        include.stringValue = spec.includePatterns.joined(separator: "; ")
        exclude.stringValue = spec.excludePatterns.joined(separator: "; ")
        for (kind, box) in kindBoxes { box.state = spec.kinds.contains(kind) ? .on : .off }
        func show(_ value: Int64?, _ field: NSTextField, _ unit: NSPopUpButton) {
            guard let value else {
                field.stringValue = ""
                return
            }
            let index = Self.units.lastIndex { value >= $0.1 && value % $0.1 == 0 } ?? 0
            unit.selectItem(at: index)
            field.stringValue = String(Double(value) / Double(Self.units[index].1))
                .replacingOccurrences(of: ".0", with: "")
        }
        show(spec.minBytes, minSize, minUnit)
        show(spec.maxBytes, maxSize, maxUnit)
        afterBox.state = spec.modifiedAfter == nil ? .off : .on
        beforeBox.state = spec.modifiedBefore == nil ? .off : .on
        afterDate.dateValue = spec.modifiedAfter ?? Date().addingTimeInterval(-30 * 86_400)
        beforeDate.dateValue = spec.modifiedBefore ?? Date()
        recurseBox.state = spec.recurse ? .on : .off
        structureBox.state = spec.keepStructure ? .on : .off
        hiddenBox.state = spec.includeHidden ? .on : .off
        updateDateEnabled()
    }

    private func updateDateEnabled() {
        afterDate.isEnabled = afterBox.state == .on
        beforeDate.isEnabled = beforeBox.state == .on
    }

    // MARK: Preview

    @objc private func controlsChanged(_ sender: Any?) {
        updateDateEnabled()
        schedulePreview()
    }

    func controlTextDidChange(_ obj: Notification) { schedulePreview() }

    private func schedulePreview(immediately: Bool = false) {
        previewFlag?.cancel()
        previewDelay?.cancel()
        lastResult = nil
        runButton.isEnabled = false
        summary.stringValue = L("filtered.counting", "Counting matches…")
        spinner.startAnimation(nil)
        let work = DispatchWorkItem { [weak self] in self?.startPreview() }
        previewDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.25), execute: work)
    }

    private func startPreview() {
        let spec = currentSpec()
        let sources = self.sources
        let flag = CancelFlag()
        previewFlag = flag
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileFilterEnumerator.run(spec, sources: sources) { flag.isCancelled }
            await MainActor.run { [weak self] in
                guard let self, !flag.isCancelled, self.previewFlag === flag else { return }
                self.show(result)
            }
        }
    }

    private func show(_ result: FileFilterEnumerator.Result) {
        spinner.stopAnimation(nil)
        lastResult = result
        let size = ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)
        var text: String
        if result.matches.isEmpty {
            text = L("filtered.noMatches", "No matching files")
        } else {
            text = String(
                format: result.fileCount == 1
                    ? L("filtered.countOne", "1 file, %@")
                    : L("filtered.countMany", "%d files, %@"),
                arguments: result.fileCount == 1 ? [size] : [result.fileCount, size])
            if result.folderCount > 0 {
                text +=
                    " "
                    + String(
                        format: L("filtered.plusFolders", "plus %d folders"), result.folderCount)
            }
        }
        if result.truncated {
            text += " " + L("filtered.truncated", "(stopped at the safety limit)")
        }
        summary.stringValue = text
        let shown = result.matches.prefix(12).map(\.relativePath)
        var lines = shown.joined(separator: "\n")
        if result.matches.count > shown.count {
            lines +=
                "\n"
                + String(
                    format: L("filtered.andMore", "and %d more"), result.matches.count - shown.count
                )
        }
        list.string = lines
        runButton.isEnabled = !result.matches.isEmpty
        panel.contentView?.setAccessibilityLabel(text)
        NSAccessibility.post(
            element: summary, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    /// PATHEM_FILTER_SHOT: wait for the preview, then hand back the sheet's view for a render.
    var debugPreviewReady: Bool { lastResult != nil }
    var debugContentView: NSView? { panel.contentView }
    var debugSummary: String { summary.stringValue }
    func debugSet(include text: String, exclude: String = "", kinds: Set<FileFilter.Kind> = []) {
        include.stringValue = text
        self.exclude.stringValue = exclude
        for (kind, box) in kindBoxes { box.state = kinds.contains(kind) ? .on : .off }
        schedulePreview(immediately: true)
    }
    func debugClose() { finish(.cancel) }
    func debugRun() { runTapped(nil) }
    func debugRender(to path: String) {
        guard let view = panel.contentView else { return }
        view.appearance = host?.effectiveAppearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Buttons and presets

    @objc private func runTapped(_ sender: Any?) {
        guard let result = lastResult, !result.matches.isEmpty else { return }
        let spec = currentSpec()
        presetsStore.last = spec
        ConfigStore.save(presetsStore, to: presetsURL)
        let handler = onRun
        finish(.OK)
        handler?(spec, result)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        // The last filter is remembered even when the run is abandoned.
        presetsStore.last = currentSpec()
        ConfigStore.save(presetsStore, to: presetsURL)
        finish(.cancel)
    }

    private func rebuildPresetMenu() {
        presetButton.removeAllItems()
        presetButton.addItem(withTitle: L("filtered.presets", "Presets"))
        for preset in presetsStore.presets {
            presetButton.menu?.addItem(
                withTitle: preset.name, action: #selector(presetChosen(_:)), keyEquivalent: "")
            presetButton.menu?.items.last?.target = self
        }
        if !presetsStore.presets.isEmpty { presetButton.menu?.addItem(.separator()) }
        let save = presetButton.menu?.addItem(
            withTitle: L("filtered.savePreset", "Save Current Filter as Preset…"),
            action: #selector(savePreset(_:)), keyEquivalent: "")
        save?.target = self
        if !presetsStore.presets.isEmpty {
            let remove = NSMenuItem(
                title: L("filtered.removePreset", "Remove Preset"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for preset in presetsStore.presets {
                let item = sub.addItem(
                    withTitle: preset.name, action: #selector(removePreset(_:)), keyEquivalent: "")
                item.target = self
            }
            remove.submenu = sub
            presetButton.menu?.addItem(remove)
        }
    }

    @objc private func presetChosen(_ sender: NSMenuItem) {
        guard let preset = presetsStore.presets.first(where: { $0.name == sender.title }) else {
            return
        }
        apply(preset.spec)
        schedulePreview(immediately: true)
    }

    @objc private func removePreset(_ sender: NSMenuItem) {
        presetsStore.remove(sender.title)
        ConfigStore.save(presetsStore, to: presetsURL)
        rebuildPresetMenu()
    }

    @objc private func savePreset(_ sender: Any?) {
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        name.stringValue = currentSpec().includePatterns.joined(separator: " ")
        let alert = NSAlert()
        alert.messageText = L("filtered.presetNameTitle", "Name this preset")
        alert.accessoryView = name
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.presetsStore.save(self.currentSpec(), as: name.stringValue)
            ConfigStore.save(self.presetsStore, to: self.presetsURL)
            self.rebuildPresetMenu()
        }
    }

    // MARK: Layout

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    private func build() {
        titleLabel.font = .boldSystemFont(ofSize: 15)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        include.placeholderString = "*.jpg; *.png"
        exclude.placeholderString = "*-draft.*; node_modules"
        for field in [include, exclude, minSize, maxSize] {
            field.delegate = self
            field.controlSize = .small
        }
        minSize.placeholderString = L("filtered.any", "any")
        maxSize.placeholderString = L("filtered.any", "any")
        minSize.alignment = .right
        maxSize.alignment = .right
        for unit in [minUnit, maxUnit] {
            unit.addItems(withTitles: Self.units.map(\.0))
            unit.selectItem(at: 1)
            unit.controlSize = .small
            unit.target = self
            unit.action = #selector(controlsChanged(_:))
        }

        let kindTitles: [(FileFilter.Kind, String)] = [
            (.folder, L("filtered.kindFolders", "Folders")),
            (.image, L("filtered.kindImages", "Images")),
            (.video, L("filtered.kindVideo", "Video")),
            (.audio, L("filtered.kindAudio", "Audio")),
            (.document, L("filtered.kindDocuments", "Documents")),
            (.archive, L("filtered.kindArchives", "Archives")),
            (.code, L("filtered.kindCode", "Code")),
        ]
        kindBoxes = kindTitles.map { kind, title in
            let box = NSButton(
                checkboxWithTitle: title, target: self, action: #selector(controlsChanged(_:)))
            box.controlSize = .small
            return (kind, box)
        }
        let rowOne = NSStackView(views: kindBoxes.prefix(4).map(\.1))
        let rowTwo = NSStackView(views: kindBoxes.dropFirst(4).map(\.1))
        for row in [rowOne, rowTwo] {
            row.orientation = .horizontal
            row.spacing = 12
        }
        let kindStack = NSStackView(views: [rowOne, rowTwo])
        kindStack.orientation = .vertical
        kindStack.alignment = .leading
        kindStack.spacing = 4

        afterBox.title = L("filtered.after", "After")
        beforeBox.title = L("filtered.before", "Before")
        recurseBox.title = L("filtered.recurse", "Search inside selected folders")
        structureBox.title = L("filtered.keepStructure", "Keep folder structure")
        hiddenBox.title = L("filtered.hidden", "Include hidden files")
        for date in [afterDate, beforeDate] {
            date.datePickerStyle = .textField
            date.datePickerElements = .yearMonthDay
            date.controlSize = .small
            date.target = self
            date.action = #selector(controlsChanged(_:))
        }
        for box in [afterBox, beforeBox, recurseBox, structureBox, hiddenBox] {
            box.target = self
            box.action = #selector(controlsChanged(_:))
            box.controlSize = .small
        }

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            l.font = .systemFont(ofSize: 12)
            l.widthAnchor.constraint(equalToConstant: 84).isActive = true
            return l
        }
        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: [label(title)] + views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            return stack
        }
        minSize.widthAnchor.constraint(equalToConstant: 64).isActive = true
        maxSize.widthAnchor.constraint(equalToConstant: 64).isActive = true
        include.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        exclude.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let sizeRow = row(
            L("filtered.size", "Size"),
            [
                minSize, minUnit, NSTextField(labelWithString: L("filtered.to", "to")), maxSize,
                maxUnit,
            ])
        let dateRow = row(
            L("filtered.modified", "Modified"), [afterBox, afterDate, beforeBox, beforeDate])
        let optionRow = row("", [recurseBox])
        let structureRow = row("", [structureBox, hiddenBox])

        summary.font = .boldSystemFont(ofSize: 12)
        list.isEditable = false
        list.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        list.textColor = .secondaryLabelColor
        list.drawsBackground = false
        list.textContainerInset = NSSize(width: 4, height: 4)
        list.isVerticallyResizable = true
        list.isHorizontallyResizable = false
        list.autoresizingMask = [.width]
        list.minSize = NSSize(width: 0, height: 0)
        list.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        list.frame = NSRect(x: 0, y: 0, width: 500, height: 150)
        list.textContainer?.widthTracksTextView = true
        list.textContainer?.containerSize = NSSize(
            width: 500, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let summaryRow = NSStackView(views: [summary, spinner])
        summaryRow.spacing = 6

        runButton.target = self
        runButton.action = #selector(runTapped(_:))
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded
        cancelButton.title = L("common.cancel", "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        presetButton.controlSize = .small
        presetButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [presetButton, spacer, cancelButton, runButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [
            titleLabel, detailLabel,
            row(L("filtered.include", "Include"), [include]),
            row(L("filtered.exclude", "Exclude"), [exclude]),
            row(L("filtered.kinds", "Kinds"), [kindStack]),
            sizeRow, dateRow, optionRow, structureRow,
            summaryRow, scroll, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        let content = SheetBackgroundView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 540),
        ])
        panel.contentView = content
    }
}

/// The sheet's content view, painting the window background itself so it reads the same
/// whether shown as a sheet or rendered offscreen.
private final class SheetBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
