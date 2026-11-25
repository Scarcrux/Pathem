import AppKit
import PathemEngine

/// The find-as-you-type bar at the bottom of a pane: a mode label (Find, Filter, Go), the text
/// field, and a one-line result readout. Pure view; `TypeAheadController` drives it.
@MainActor
final class TypeAheadBar: NSView {
    let segments = NSSegmentedControl(
        labels: [
            L("typeahead.find", "Find"), L("typeahead.filter", "Filter"), L("typeahead.go", "Go"),
        ],
        trackingMode: .selectOne, target: nil, action: nil)
    let field = NSTextField()
    let readout = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        segments.controlSize = .small
        segments.segmentStyle = .rounded
        segments.focusRingType = .none
        segments.refusesFirstResponder = true
        segments.setContentHuggingPriority(.required, for: .horizontal)
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = L(
            "typeahead.placeholder", "Type to find. / to go, > for commands, ? to search")
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        readout.font = .systemFont(ofSize: 11)
        readout.textColor = .secondaryLabelColor
        readout.lineBreakMode = .byTruncatingTail
        readout.alignment = .right
        readout.setContentHuggingPriority(.init(250), for: .horizontal)
        readout.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let row = NSStackView(views: [segments, field, readout])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            readout.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("typeahead.a11y", "Find as you type"))
        applyTheme()
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ThemeManager.shared.contentBackground.cgColor
            layer?.borderColor = ThemeManager.shared.accent.withAlphaComponent(0.55).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }
}

/// What the app layer supplies to the bar: the command list for `>`, the semantic-search entry
/// point for `?`, and why semantic search can't run on this pane (shown instead of results).
struct TypeAheadHooks {
    var commandItems: () -> [TypeAhead.CommandItem] = { [] }
    var runCommand: (String) -> Void = { _ in }
    var semanticSearch: (String) -> Void = { _ in }
    var semanticRefusal: () -> String? = { nil }
}

/// The state machine behind the bar. It owns no file state: it asks the pane for entries and
/// selection, drives the pane's existing quick filter for Filter mode, the pane's navigation
/// for Go mode, and the app's command registry / semantic search through `hooks`.
@MainActor
final class TypeAheadController: NSObject, NSTextFieldDelegate {
    unowned let pane: PaneController
    let bar = TypeAheadBar()
    var hooks = TypeAheadHooks()
    /// Idle time before Find mode closes itself.
    var idleSeconds: TimeInterval = 2.0

    private(set) var manualMode: TypeAheadMode = .find
    private(set) var effectiveMode: TypeAheadMode = .find
    private var matches: [Int] = []  // indices into the pane's entries (Find)
    private var cursor = 0
    private var commandHits: [TypeAhead.CommandItem] = []
    private var savedSelection: Set<String> = []
    private var savedFilter = ""
    private var filterApplied = false
    private var semanticRan = false
    private var idle: DispatchWorkItem?
    private var closing = false

    var isOpen: Bool { !bar.isHidden }
    var text: String { bar.field.stringValue }

    override init() {
        fatalError("use init(pane:)")
    }

    init(pane: PaneController) {
        self.pane = pane
        super.init()
        bar.field.delegate = self
        bar.segments.target = self
        bar.segments.action = #selector(segmentClicked)
    }

    // MARK: Open and close

    /// Show the bar seeded with `seed` (the first typed character) and take focus.
    func open(seed: String = "") {
        guard let window = pane.containerView.window else { return }
        if !isOpen {
            savedSelection = Set(pane.selectedEntries.map(\.name))
            savedFilter = pane.currentFilterText
            filterApplied = false
            semanticRan = false
            matches = []
            cursor = 0
            manualMode = .find
            effectiveMode = .find
            closing = false
            bar.isHidden = false
        }
        bar.field.stringValue = seed
        window.makeFirstResponder(bar.field)
        if let editor = bar.field.currentEditor() {
            editor.selectedRange = NSRange(location: (seed as NSString).length, length: 0)
        }
        textChanged()
    }

    /// Close the bar. `restore` puts the selection and filter back as they were when it opened
    /// (Esc); otherwise what the user reached stays (Return, auto-hide, clicking away).
    func close(restore: Bool, keepFilter: Bool = false, keepSearch: Bool = false) {
        guard isOpen, !closing else { return }
        closing = true
        idle?.cancel()
        if filterApplied, !keepFilter { pane.setFilter(savedFilter) }
        if semanticRan, !keepSearch { hooks.semanticSearch("") }
        if restore, effectiveMode != .semantic { pane.selectNames(savedSelection) }
        bar.field.stringValue = ""
        bar.isHidden = true
        pane.focusList()
        closing = false
    }

    // MARK: Text changes

    func controlTextDidChange(_ obj: Notification) { textChanged() }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicked away (Return and Esc go through doCommandBy, which closes first).
        guard isOpen, !closing else { return }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.other.rawValue || movement == 0 {
            close(restore: false, keepFilter: effectiveMode == .filter)
        }
    }

    private func textChanged() {
        let parsed = TypeAhead.parse(text, manual: manualMode)
        let previous = effectiveMode
        effectiveMode = parsed.mode
        if previous != parsed.mode { leave(previous) }
        switch parsed.mode {
        case .find: applyFind(parsed.query)
        case .filter: applyFilter(parsed.query)
        case .go: applyGo(parsed.query)
        case .command: applyCommand(parsed.query)
        case .semantic: applySemantic(parsed.query)
        }
        syncSegments()
        announce()
        scheduleIdle()
    }

    /// Undo the previous mode's effect on the pane when the text moves to another mode.
    private func leave(_ mode: TypeAheadMode) {
        switch mode {
        case .filter:
            if filterApplied {
                pane.setFilter(savedFilter)
                filterApplied = false
            }
        case .semantic:
            if semanticRan {
                hooks.semanticSearch("")
                semanticRan = false
            }
        default: break
        }
    }

    private func applyFind(_ query: String) {
        let names = pane.entries.map(\.name)
        matches = TypeAhead.matches(names: names, query: query)
        cursor = 0
        if let first = matches.first {
            pane.select(name: names[first])
            readout(
                String(format: L("typeahead.matchCount", "%d of %d"), 1, matches.count))
        } else {
            readout(query.isEmpty ? "" : L("typeahead.noMatches", "No matches"))
        }
    }

    private func applyFilter(_ query: String) {
        pane.setFilter(query)
        filterApplied = true
        let shown = pane.entries.count
        readout(
            query.isEmpty
                ? ""
                : (shown == 0
                    ? L("typeahead.noMatches", "No matches")
                    : String(format: L("typeahead.shown", "%d shown"), shown)))
    }

    private func applyGo(_ query: String) {
        let completion = TypeAhead.completeGo(query, base: pane.currentURL)
        switch completion.candidates.count {
        case 0:
            readout(L("typeahead.noFolders", "No matching folder"))
        case 1:
            readout(completion.candidates[0] + "/")
        default:
            readout(
                String(format: L("typeahead.folders", "%d folders"), completion.candidates.count))
        }
    }

    private func applyCommand(_ query: String) {
        commandHits = TypeAhead.rankCommands(hooks.commandItems(), query: query)
        cursor = 0
        showCommand()
    }

    private func showCommand() {
        guard !commandHits.isEmpty else {
            readout(L("typeahead.noCommand", "No matching command"))
            return
        }
        readout(
            "\(commandHits[cursor].title)  (\(cursor + 1)/\(commandHits.count))")
    }

    private var semanticWork: DispatchWorkItem?
    private func applySemantic(_ query: String) {
        semanticWork?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let refusal = hooks.semanticRefusal() {
            readout(refusal)
            return
        }
        guard !trimmed.isEmpty else {
            readout(L("typeahead.searchHint", "Describe what you are looking for"))
            return
        }
        readout(L("typeahead.searching", "Searching this folder"))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen, self.effectiveMode == .semantic else { return }
            self.semanticRan = true
            self.hooks.semanticSearch(trimmed)
        }
        semanticWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.275, execute: work)
    }

    // MARK: Keys

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close(restore: true)
        case #selector(NSResponder.insertNewline(_:)):
            commit()
        case #selector(NSResponder.insertTab(_:)):
            tab(forward: true)
        case #selector(NSResponder.insertBacktab(_:)):
            tab(forward: false)
        case #selector(NSResponder.moveDown(_:)):
            move(forward: true)
        case #selector(NSResponder.moveUp(_:)):
            move(forward: false)
        default:
            return false
        }
        return true
    }

    private func tab(forward: Bool) {
        switch effectiveMode {
        case .find, .filter:
            // Cycle the manual mode; the text is kept, so Find re-matches or Filter re-applies.
            manualMode = TypeAhead.cycled(effectiveMode)
            textChanged()
        case .go:
            let completion = TypeAhead.completeGo(text, base: pane.currentURL)
            if let completed = completion.completed {
                bar.field.stringValue = completed
                bar.field.currentEditor()?.selectedRange = NSRange(
                    location: (completed as NSString).length, length: 0)
                textChanged()
            } else if completion.candidates.isEmpty {
                NSSound.beep()
            }
        case .command:
            move(forward: forward)
        case .semantic:
            break
        }
    }

    private func move(forward: Bool) {
        scheduleIdle()
        switch effectiveMode {
        case .find:
            guard let next = TypeAhead.step(from: cursor, count: matches.count, forward: forward)
            else { return NSSound.beep() }
            cursor = next
            pane.select(name: pane.entries[matches[next]].name)
            readout(
                String(format: L("typeahead.matchCount", "%d of %d"), next + 1, matches.count))
            announce()
        case .filter, .semantic:
            pane.moveSelection(by: forward ? 1 : -1)
        case .command:
            guard
                let next = TypeAhead.step(from: cursor, count: commandHits.count, forward: forward)
            else { return }
            cursor = next
            showCommand()
        case .go:
            break
        }
    }

    private func commit() {
        switch effectiveMode {
        case .find:
            let hadMatch = !matches.isEmpty
            close(restore: false)
            if hadMatch { pane.openSelection() }
        case .filter:
            // Keep the filter: hand it to the pane's own filter field so it can be cleared later.
            let query = text
            close(restore: false, keepFilter: true)
            pane.adoptFilter(query)
        case .go:
            goToTyped()
        case .command:
            guard !commandHits.isEmpty else { return NSSound.beep() }
            let id = commandHits[cursor].id
            close(restore: false)
            hooks.runCommand(id)
        case .semantic:
            semanticWork?.cancel()
            let query = TypeAhead.parse(text, manual: manualMode).query
                .trimmingCharacters(in: .whitespaces)
            if hooks.semanticRefusal() == nil, !query.isEmpty, !semanticRan {
                hooks.semanticSearch(query)
                semanticRan = true
            }
            close(restore: false, keepSearch: true)
        }
    }

    private func goToTyped() {
        switch TypeAhead.goTarget(text, base: pane.currentURL) {
        case .folder(let url):
            close(restore: false)
            pane.navigate(to: url)
        case .file(let url):
            close(restore: false)
            pane.navigate(to: url.deletingLastPathComponent())
            pane.selectWhenListed(url.lastPathComponent)
        case .missing(let requested, let suggestion):
            let message =
                suggestion.map {
                    String(
                        format: L("typeahead.didYouMean", "“%@” doesn't exist. Did you mean %@?"),
                        requested.path, $0.path)
                }
                ?? String(
                    format: L("typeahead.noSuchPath", "“%@” doesn't exist."), requested.path)
            pane.flashStatus(message, isError: true)
            NSSound.beep()
        }
    }

    // MARK: Chrome

    @objc private func segmentClicked() {
        switch bar.segments.selectedSegment {
        case 0:
            manualMode = .find
            if effectiveMode != .find, effectiveMode != .filter { stripPrefixForManual() }
        case 1:
            manualMode = .filter
            if effectiveMode != .find, effectiveMode != .filter { stripPrefixForManual() }
        case 2:
            if effectiveMode != .go { bar.field.stringValue = "~/" }
        default: break
        }
        pane.containerView.window?.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectedRange = NSRange(
            location: (bar.field.stringValue as NSString).length, length: 0)
        textChanged()
    }

    /// Picking Find or Filter while a prefix mode is active drops the prefix text.
    private func stripPrefixForManual() { bar.field.stringValue = "" }

    private func syncSegments() {
        switch effectiveMode {
        case .find: bar.segments.selectedSegment = 0
        case .filter: bar.segments.selectedSegment = 1
        case .go: bar.segments.selectedSegment = 2
        default: bar.segments.selectedSegment = -1
        }
    }

    private func readout(_ text: String) {
        let prefix: String
        switch effectiveMode {
        case .command: prefix = L("typeahead.commandTag", "Command") + "  "
        case .semantic: prefix = L("typeahead.searchTag", "Search") + "  "
        default: prefix = ""
        }
        bar.readout.stringValue = text.isEmpty ? String(prefix.dropLast(2)) : prefix + text
    }

    private var lastAnnouncement = ""
    private func announce() {
        let mode: String
        switch effectiveMode {
        case .find: mode = L("typeahead.find", "Find")
        case .filter: mode = L("typeahead.filter", "Filter")
        case .go: mode = L("typeahead.go", "Go")
        case .command: mode = L("typeahead.commandTag", "Command")
        case .semantic: mode = L("typeahead.searchTag", "Search")
        }
        let summary = "\(mode). \(bar.readout.stringValue)"
        bar.field.setAccessibilityLabel(summary)
        guard summary != lastAnnouncement else { return }
        lastAnnouncement = summary
        NSAccessibility.post(
            element: bar.field, notification: .announcementRequested,
            userInfo: [
                .announcement: summary, .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ])
    }

    /// Find mode only: hide the bar after a quiet moment, leaving the selection where it is.
    private func scheduleIdle() {
        idle?.cancel()
        guard effectiveMode == .find else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen, self.effectiveMode == .find else { return }
            self.close(restore: false)
        }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleSeconds, execute: work)
    }
}
