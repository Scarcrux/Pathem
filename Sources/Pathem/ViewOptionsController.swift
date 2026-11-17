import AppKit
import PathemEngine

/// A folder-scoped, scrollable inspector. Reading controls is side-effect-free; the browser
/// commits the snapshot only after Apply, and keeps the originating folder through async sheets.
@MainActor
final class ViewOptionsController: NSObject {
    let alert = NSAlert()
    let mode = NSPopUpButton()
    let sort = NSPopUpButton()
    let group = NSPopUpButton()
    let dates = NSPopUpButton()
    let font = NSPopUpButton()
    let listIcons = NSPopUpButton()
    let iconScale = NSSlider(value: 1, minValue: 0.5, maxValue: 3, target: nil, action: nil)
    let spacing = NSSlider(value: 8, minValue: 0, maxValue: 64, target: nil, action: nil)
    let position = NSPopUpButton()
    let relative = NSButton(
        checkboxWithTitle: L("viewopts.relative", "Use relative dates (Today, Yesterday)"),
        target: nil, action: nil)
    let ascending = NSButton(
        checkboxWithTitle: L("viewopts.ascending", "Ascending"), target: nil, action: nil)
    let previews = NSButton(
        checkboxWithTitle: L("viewopts.previews", "Show icon preview"), target: nil, action: nil)
    let sizes = NSButton(
        checkboxWithTitle: L("bvc.cmd.calculateAllSizes", "Calculate All Sizes"), target: nil,
        action: nil)
    let library = NSButton(
        checkboxWithTitle: L("viewopts.library", "Show Library Folder (in Home)"), target: nil,
        action: nil)
    let subfolders = NSButton(
        checkboxWithTitle: L(
            "viewopts.subfolders", "Also apply to subfolders (replaces their saved views)"),
        target: nil, action: nil)
    private var columns: [(id: String, button: NSButton)] = []
    private let original: ViewFormat
    private let snapshotOptions: FolderViewOptions

    init(format: ViewFormat, effective: FolderViewOptions, folderName: String) {
        original = format
        snapshotOptions = effective
        super.init()
        alert.messageText = L("viewopts.title", "View Options") + " — " + folderName
        alert.informativeText = L(
            "viewopts.hint",
            "Settings are remembered for this folder. Unsupported metadata stays blank.")
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("viewopts.defaults", "Use as Defaults"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 145).isActive = true
            let line = NSStackView(views: [label, control])
            line.spacing = 10
            stack.addArrangedSubview(line)
        }
        mode.addItems(withTitles: [
            L("pane.list", "List"), L("pane.icons", "Icons"), L("pane.gallery", "Gallery"),
            L("pane.columns", "Columns"), L("pane.tree", "Tree"),
        ])
        mode.selectItem(at: ViewFormat.ViewMode.allCases.firstIndex(of: format.viewMode) ?? 0)
        sort.addItems(withTitles: ViewFormat.SortKey.allCases.map(\.localizedTitle))
        sort.selectItem(at: ViewFormat.SortKey.allCases.firstIndex(of: format.sortKey) ?? 0)
        group.addItems(withTitles: ViewFormat.GroupKey.allCases.map(\.localizedTitle))
        group.selectItem(at: ViewFormat.GroupKey.allCases.firstIndex(of: format.groupKey) ?? 0)
        dates.addItems(withTitles: [
            L("prefs.dateShort", "Short (7/8/26, 3:14 PM)"),
            L("prefs.dateMedium", "Medium (Jul 8, 2026)"),
        ])
        dates.selectItem(at: effective.dateDisplay == .short ? 0 : 1)
        relative.state = effective.dateDisplay == .relative ? .on : .off
        relative.identifier = .init("relativeDates")
        font.addItems(withTitles: (9...24).map(String.init))
        font.selectItem(withTitle: String(effective.fontSize ?? 13))
        listIcons.addItems(withTitles: ["16", "24", "32", "48", "64"])
        listIcons.selectItem(withTitle: String(effective.listIconSize ?? 16))
        iconScale.doubleValue = effective.iconScale ?? 1
        spacing.doubleValue = Double(effective.gridSpacing ?? 8)
        position.addItems(withTitles: [L("viewopts.below", "Below"), L("viewopts.right", "Right")])
        position.selectItem(at: effective.labelPosition == .right ? 1 : 0)
        ascending.state = format.ascending ? .on : .off
        previews.state = effective.showIconPreviews == false ? .off : .on
        sizes.state = effective.calculateFolderSizes == true ? .on : .off
        library.state = effective.showLibraryFolder == true ? .on : .off
        row(L("viewopts.openAs", "Always open as"), mode)
        row(L("prefs.defaultSortLabel", "Default sort"), sort)
        stack.addArrangedSubview(ascending)
        row(L("viewopts.group", "Group by"), group)
        row(L("prefs.fontSizeLabel", "Font size"), font)
        stack.addArrangedSubview(relative)
        row(L("viewopts.absoluteDates", "Non-relative date style"), dates)
        row(L("viewopts.listIcons", "List icon size"), listIcons)
        row(L("viewopts.iconScale", "Icon size (Icon view)"), iconScale)
        row(L("viewopts.spacing", "Grid spacing (Icon view)"), spacing)
        row(L("viewopts.labels", "Labels (Icon view)"), position)
        for button in [previews, sizes, library] { stack.addArrangedSubview(button) }
        stack.addArrangedSubview(
            NSTextField(labelWithString: L("viewopts.columns", "Show columns (List view)")))
        let visible = effective.columns ?? ["name", "size", "date"]
        for column in FileListController.viewOptionColumns {
            let button = NSButton(checkboxWithTitle: column.title, target: nil, action: nil)
            button.state = visible.contains(column.id) ? .on : .off
            button.isEnabled = column.id != "name"
            button.identifier = .init(column.id)
            columns.append((column.id, button))
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(subfolders)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 450))
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(
                equalTo: scroll.contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
        ])
        alert.accessoryView = scroll
        mode.target = self
        mode.action = #selector(updateCapabilities)
        updateCapabilities()
    }

    /// Keep the sheet within its host by scrolling the controls, not clipping the buttons.
    func fit(in host: NSWindow) {
        guard let scroll = alert.accessoryView as? NSScrollView else { return }
        alert.layout()
        let originalHeight = alert.window.frame.height
        let available = min(
            host.contentLayoutRect.height,
            host.screen?.visibleFrame.height ?? host.contentLayoutRect.height)
        let overflow = max(0, originalHeight - available)
        guard overflow > 0 else { return }
        scroll.setFrameSize(
            NSSize(width: scroll.frame.width, height: max(44, scroll.frame.height - overflow)))
        alert.layout()
        #if DEBUG
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_TEST"] == "1" {
            let receipt =
                "TSAMPLE: VIEW-OPTIONS-HEIGHT available=\(available) before=\(originalHeight) after=\(alert.window.frame.height) viewport=\(scroll.frame.height)\n"
            FileHandle.standardOutput.write(Data(receipt.utf8))
        }
        #endif
    }

    @objc func updateCapabilities() {
        let selected = ViewFormat.ViewMode.allCases[max(0, mode.indexOfSelectedItem)]
        let isList = selected == .list
        let isIcon = selected == .icon
        group.isEnabled = isList || isIcon
        dates.isEnabled = isList || selected == .column
        relative.isEnabled = dates.isEnabled
        listIcons.isEnabled = isList
        iconScale.isEnabled = isIcon
        spacing.isEnabled = isIcon
        position.isEnabled = isIcon
        previews.isEnabled = isList || isIcon || selected == .gallery
        sizes.isEnabled = isList
        for column in columns { column.button.isEnabled = isList && column.id != "name" }
    }

    var format: ViewFormat {
        var result = original
        result.options = snapshotOptions
        result.viewMode = ViewFormat.ViewMode.allCases[max(0, mode.indexOfSelectedItem)]
        result.sortKey = ViewFormat.SortKey.allCases[max(0, sort.indexOfSelectedItem)]
        result.groupKey = ViewFormat.GroupKey.allCases[max(0, group.indexOfSelectedItem)]
        result.ascending = ascending.state == .on
        result.options.fontSize = Int(font.titleOfSelectedItem ?? "13")
        result.options.dateDisplay =
            relative.state == .on ? .relative : (dates.indexOfSelectedItem == 0 ? .short : .medium)
        result.options.listIconSize = Int(listIcons.titleOfSelectedItem ?? "16")
        result.options.iconScale = iconScale.doubleValue
        result.options.gridSpacing = Int(spacing.doubleValue.rounded())
        result.options.labelPosition = position.indexOfSelectedItem == 1 ? .right : .below
        result.options.showIconPreviews = previews.state == .on
        result.options.calculateFolderSizes = sizes.state == .on
        result.options.showLibraryFolder = library.state == .on
        let selected = Set(columns.filter { $0.button.state == .on }.map(\.id))
        let order = snapshotOptions.columns ?? FolderViewOptions.columnIDs
        result.options.columns =
            order.filter { selected.contains($0) }
            + FolderViewOptions.columnIDs.filter { selected.contains($0) && !order.contains($0) }
        return result
    }
}
