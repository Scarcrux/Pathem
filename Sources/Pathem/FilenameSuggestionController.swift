import AppKit
import PathemEngine

/// One suggestion session per rename/save field. A response never writes the field: only the
/// explicit Use button can do that. Cancelling invalidates delivery, even if the model ignores cancellation.
@MainActor
final class FilenameSuggestionController: NSObject {
    let view: NSStackView
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(
        title: L("names.use", "Use Suggested Name"), target: nil, action: nil)
    private weak var field: NSTextField?
    private var task: Task<Void, Never>?
    private var suggestion: String?
    private var generation = 0
    var onApply: ((String) -> Void)?

    init(
        field: NSTextField, url: URL, dataless: Bool, extensionOverride: String? = nil,
        generateAutomatically: Bool = true
    ) {
        self.field = field
        view = NSStackView(views: [label, button])
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        label.preferredMaxLayoutWidth = 360
        button.target = self
        button.action = #selector(useSuggestion)
        button.isEnabled = false
        label.stringValue =
            AIAssistant.isAvailable
            ? L("names.loading", "Suggesting a filename on this Mac…")
            : AIAssistant.availability.reason
        guard AIAssistant.isAvailable, !dataless, generateAutomatically else {
            if dataless {
                label.stringValue = L(
                    "names.onlineOnly",
                    "Download this file before suggesting a name from its contents.")
            }
            return
        }
        start(
            url: url, extensionOverride: extensionOverride,
            preview: { url in
                await Task.detached { BrowserViewController.textPreview(of: url) }.value
            },
            suggest: { name, preview in
                await AIAssistant.suggestName(currentName: name, content: preview)
            })
    }

    private func start(
        url: URL, extensionOverride: String?,
        preview: @escaping @MainActor (URL) async -> String?,
        suggest: @escaping @MainActor (String, String?) async -> String?
    ) {
        let token = generation
        task = Task { @MainActor [weak self] in
            defer {
                #if DEBUG
                self?.debugFinished = true
                #endif
            }
            let content = await preview(url)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            let base = await suggest(url.lastPathComponent, content)
            guard !Task.isCancelled, self.generation == token else { return }
            self.receive(base, ext: extensionOverride ?? url.pathExtension, token: token)
        }
    }

    private func receive(_ base: String?, ext: String, token: Int) {
        guard generation == token, field != nil else { return }
        if let base = base.flatMap(AIAssistant.sanitizeSuggestedName) {
            suggestion = ext.isEmpty ? base : "\(base).\(ext)"
            label.stringValue = suggestion ?? ""
            button.isEnabled = true
        } else {
            label.stringValue = L(
                "names.failed", "No suggestion available. You can still enter a name.")
        }
    }

    #if DEBUG
    private(set) var debugFinished = false
    func debugStart(
        preview: @escaping @MainActor (URL) async -> String?,
        suggest: @escaping @MainActor (String, String?) async -> String?
    ) {
        start(
            url: URL(fileURLWithPath: "/fixture/original.txt"), extensionOverride: nil,
            preview: preview, suggest: suggest)
    }
    func debugDeliver(_ base: String, ext: String) { receive(base, ext: ext, token: 0) }
    func debugUse() { useSuggestion() }
    #endif

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        field = nil
    }

    @objc private func useSuggestion() {
        guard let suggestion, let field else { return }
        field.stringValue = suggestion
        onApply?(suggestion)
        field.selectText(nil)
    }
}
