import AppKit
import PathemEngine

/// A bulk metadata inspector: edit the capture date, description, author, copyright,
/// and keywords (EXIF/IPTC, written losslessly via `ImageMetadata`) plus Finder tags
/// and the Spotlight comment, across a whole selection at once. Fields shared by
/// every item are prefilled; fields that differ start blank with a "multiple values"
/// hint. Only fields you actually touch are written, so a mixed selection is never
/// clobbered. Image-only fields disable when nothing in the selection is an image.
@MainActor
final class MetadataEditorController: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private weak var host: NSWindow?
    private var imageURLs: [URL] = []  // EXIF/IPTC targets
    private var allURLs: [URL] = []  // tag/comment targets (any file)

    // Controls
    private let headerLabel = NSTextField(labelWithString: "")
    private let dateCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let descriptionField = NSTextField()
    private let authorField = NSTextField()
    private let copyrightField = NSTextField()
    private let keywordsField = NSTextField()
    private let tagsField = NSTextField()
    private let commentField = NSTextField()
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    /// Which text fields the user has touched (only these get written).
    private var edited: Set<String> = []

    /// Called with the number of items successfully updated.
    var onApplied: ((Int) -> Void)?

    func present(urls: [URL], over host: NSWindow?) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        self.host = host
        self.allURLs = urls
        self.imageURLs = urls.filter { BrowserViewController.isImageName($0.lastPathComponent) }
        self.edited = []
        buildWindowIfNeeded()

        headerLabel.stringValue =
            urls.count == 1
            ? urls[0].lastPathComponent
            : String(format: L("meta.editingCount", "Editing %d items"), urls.count)

        setImageFieldsEnabled(false)  // until the baseline loads
        spinner.startAnimation(nil)
        loadBaseline()

        if let window {
            if let host { host.beginSheet(window) { _ in } } else { window.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: Build

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        headerLabel.font = .boldSystemFont(ofSize: 13)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        dateCheck.title = L("meta.setCaptureDate", "Set capture date")
        dateCheck.target = self
        dateCheck.action = #selector(dateCheckToggled)
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        datePicker.isEnabled = false
        datePicker.target = self
        datePicker.action = #selector(dateChanged)

        for field in [descriptionField, authorField, copyrightField, keywordsField, tagsField, commentField] {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        }
        descriptionField.identifier = .init("description")
        authorField.identifier = .init("author")
        copyrightField.identifier = .init("copyright")
        keywordsField.identifier = .init("keywords")
        tagsField.identifier = .init("tags")
        commentField.identifier = .init("comment")
        keywordsField.placeholderString = L("meta.commaSeparated", "comma separated")
        tagsField.placeholderString = L("meta.commaSeparated", "comma separated")

        let dateRow = NSStackView(views: [dateCheck, datePicker])
        dateRow.orientation = .horizontal
        dateRow.spacing = 8

        let grid = NSGridView(views: [
            [label(L("meta.fieldImage", "IMAGE (EXIF / IPTC)"), section: true), NSGridCell.emptyContentView],
            [label(L("meta.captureDate", "Capture Date:")), dateRow],
            [label(L("meta.description", "Description:")), descriptionField],
            [label(L("meta.author", "Author:")), authorField],
            [label(L("meta.copyright", "Copyright:")), copyrightField],
            [label(L("meta.keywords", "Keywords:")), keywordsField],
            [label(L("meta.fieldFinder", "FINDER (any file)"), section: true), NSGridCell.emptyContentView],
            [label(L("meta.tags", "Tags:")), tagsField],
            [label(L("meta.comment", "Comment:")), commentField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10

        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        applyButton.title = L("meta.apply", "Apply")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        let footer = NSStackView(views: [spinner, NSView(), cancel, applyButton])
        footer.orientation = .horizontal

        let headerRow = NSStackView(views: [headerLabel, NSView()])
        headerRow.orientation = .horizontal

        let content = NSStackView(views: [headerRow, grid, footer])
        content.orientation = .vertical
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        content.setHuggingPriority(.defaultLow, for: .horizontal)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = L("meta.windowTitle", "Edit Metadata")
        window.contentView = content
        window.center()
        self.window = window
    }

    private func label(_ text: String, section: Bool = false) -> NSView {
        let field = NSTextField(labelWithString: text)
        if section {
            field.font = .systemFont(ofSize: 10, weight: .semibold)
            field.textColor = .tertiaryLabelColor
        }
        return field
    }

    // MARK: Baseline

    private func loadBaseline() {
        let imageURLs = self.imageURLs
        let allURLs = self.allURLs
        Task { @MainActor in
            let baseline = await Task.detached { () -> Baseline in
                Baseline(
                    fields: imageURLs.map { ImageMetadata.read($0) },
                    tags: allURLs.map { FileMetadata.tags(of: $0) },
                    comments: allURLs.map { FileMetadata.finderComment(of: $0) ?? "" })
            }.value
            self.spinner.stopAnimation(nil)
            self.populate(baseline)
        }
    }

    private struct Baseline: Sendable {
        let fields: [ImageMetadata.Fields]
        let tags: [[String]]
        let comments: [String]
    }

    private func populate(_ baseline: Baseline) {
        let hasImages = !imageURLs.isEmpty
        setImageFieldsEnabled(hasImages)

        // Prefill each field only when every item agrees; otherwise leave a hint.
        prefill(descriptionField, shared(baseline.fields.map { $0.caption ?? "" }))
        prefill(authorField, shared(baseline.fields.map { $0.author ?? "" }))
        prefill(copyrightField, shared(baseline.fields.map { $0.copyright ?? "" }))
        prefill(keywordsField, shared(baseline.fields.map { $0.keywords.joined(separator: ", ") }))
        prefill(tagsField, shared(baseline.tags.map { $0.joined(separator: ", ") }))
        prefill(commentField, shared(baseline.comments))

        let dates = baseline.fields.compactMap { $0.dateTaken }
        if baseline.fields.allSatisfy({ $0.dateTaken != nil }), let sharedDate = shared(dates) {
            datePicker.dateValue = sharedDate
        }
    }

    /// The single value shared by every item, or nil when they differ.
    private func shared(_ values: [String]) -> String? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private func shared(_ values: [Date]) -> Date? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private func prefill(_ field: NSTextField, _ value: String?) {
        if let value {
            field.stringValue = value
        } else {
            field.stringValue = ""
            field.placeholderString = L("meta.multiple", "multiple values")
        }
    }

    private func setImageFieldsEnabled(_ enabled: Bool) {
        dateCheck.isEnabled = enabled
        datePicker.isEnabled = enabled && dateCheck.state == .on
        for field in [descriptionField, authorField, copyrightField, keywordsField] {
            field.isEnabled = enabled
        }
    }

    // MARK: Editing state

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        edited.insert(id)
    }

    @objc private func dateCheckToggled() {
        datePicker.isEnabled = dateCheck.state == .on && !imageURLs.isEmpty
    }

    @objc private func dateChanged() { dateCheck.state = .on }

    // MARK: Apply

    @objc private func applyClicked() {
        var edit = ImageMetadata.Edit()
        if edited.contains("description") { edit.caption = stringEdit(descriptionField) }
        if edited.contains("author") { edit.author = stringEdit(authorField) }
        if edited.contains("copyright") { edit.copyright = stringEdit(copyrightField) }
        if edited.contains("keywords") { edit.keywords = listEdit(keywordsField) }
        if dateCheck.state == .on { edit.dateTaken = .set(datePicker.dateValue) }

        let tagsEdit: [String]? = edited.contains("tags") ? parseList(tagsField.stringValue) : nil
        let commentEdit: String? = edited.contains("comment") ? commentField.stringValue : nil

        let hasImageWork = !edit.isEmpty && !imageURLs.isEmpty
        let hasFinderWork = tagsEdit != nil || commentEdit != nil
        guard hasImageWork || hasFinderWork else { close(); return }

        let imageURLs = self.imageURLs
        let allURLs = self.allURLs
        let finalEdit = edit  // capture an immutable copy in the sending closure
        applyButton.isEnabled = false
        spinner.startAnimation(nil)

        Task { @MainActor in
            let changed = await Task.detached { () -> Int in
                var touched: Set<String> = []
                if hasImageWork {
                    for url in imageURLs where (try? ImageMetadata.apply(finalEdit, to: url)) == true {
                        touched.insert(url.path)
                    }
                }
                if let tagsEdit {
                    for url in allURLs where (try? FileMetadata.setTags(tagsEdit, on: url)) != nil {
                        touched.insert(url.path)
                    }
                }
                if let commentEdit {
                    for url in allURLs where (try? FileMetadata.setFinderComment(commentEdit, on: url)) != nil {
                        touched.insert(url.path)
                    }
                }
                return touched.count
            }.value
            self.spinner.stopAnimation(nil)
            self.close()
            self.onApplied?(changed)
        }
    }

    private func stringEdit(_ field: NSTextField) -> ImageMetadata.FieldEdit<String> {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .cleared : .set(trimmed)
    }

    private func listEdit(_ field: NSTextField) -> ImageMetadata.FieldEdit<[String]> {
        let list = parseList(field.stringValue)
        return list.isEmpty ? .cleared : .set(list)
    }

    private func parseList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @objc private func cancel() { close() }

    private func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
        self.window = nil
    }
}
