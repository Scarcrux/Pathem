import AppKit
import PathemEngine

@MainActor
enum AppExtensions {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["PATHEM_ENABLE_EXTENSIONS"] == "1"
    }

    static var directory: URL? {
        guard let root = ConfigStore.url("Extensions"),
            (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        else { return nil }
        return root
    }
    static var hostVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func approvals() -> [String: ExtensionApproval] {
        guard let url = ConfigStore.url("extension-approvals.json"),
            let info = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            info.isRegularFile == true, info.isSymbolicLink == false,
            (info.fileSize ?? Int.max) <= 1024 * 1024
        else { return [:] }
        return ConfigStore.load([String: ExtensionApproval].self, from: url) ?? [:]
    }

    static func save(_ approvals: [String: ExtensionApproval]) throws {
        guard let url = ConfigStore.url("extension-approvals.json") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = try JSONEncoder().encode(approvals)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class ExtensionSettings: NSStackView {
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func refresh() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard AppExtensions.enabled else {
            addArrangedSubview(
                label(L("ext.optIn", "Extensions require PATHEM_ENABLE_EXTENSIONS=1.")))
            return
        }
        guard ExtensionHost.isolationAvailable else {
            addArrangedSubview(
                label(
                    L(
                        "ext.isolation",
                        "Isolated extension launch could not be verified on this macOS version. Extensions are disabled."
                    )))
            return
        }
        guard let root = AppExtensions.directory else { return }
        let candidates = ExtensionHost.discover(in: root, hostVersion: AppExtensions.hostVersion)
        let approved = AppExtensions.approvals()
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: .skipsHiddenFiles)) ?? []
        let folders = entries.filter {
            guard
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        if folders.isEmpty {
            addArrangedSubview(label(L("ext.empty", "No extensions installed.")))
        }
        for folder in folders {
            let candidate = candidates.first(where: { $0.directory == folder })
            let id = candidate?.manifest.id
            let enabled = candidate.map { approved[$0.manifest.id]?.matches($0) == true } ?? false
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            let title = label(candidate?.manifest.name ?? folder.lastPathComponent)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            row.addArrangedSubview(title)
            if let candidate, let signature = candidate.signature {
                row.addArrangedSubview(label(signature.developer + " · " + signature.teamID))
                row.addArrangedSubview(
                    label(
                        enabled
                            ? L("ext.approved", "Signature verified · Approved")
                            : L("ext.pending", "Signature verified · Approval required")))
                let contributions = candidate.manifest.contributes
                let commands = contributions.commands.map(\.title)
                row.addArrangedSubview(
                    label(
                        commands.isEmpty
                            ? L("ext.noCommands", "No commands declared.")
                            : commands.joined(separator: ", ")))
                let other = [
                    (L("pane.columns", "Columns"), contributions.columns.map(\.title)),
                    (L("menu.group.preview", "Preview"), contributions.viewers.map(\.title)),
                    (L("settings.menus", "Menus"), contributions.menuItems.map(\.command)),
                    (L("settings.shortcuts", "Shortcuts"), contributions.keybindings.map(\.chord)),
                    (L("prefs.themes", "Themes"), contributions.themes.map(\.name)),
                ]
                for (kind, values) in other where !values.isEmpty {
                    row.addArrangedSubview(label(kind + " · " + values.joined(separator: ", ")))
                }
            } else {
                row.addArrangedSubview(
                    label(
                        L("ext.invalid", "Invalid signature, manifest, or duplicate extension ID."))
                )
            }
            let buttons = NSStackView()
            if let candidate, let id {
                buttons.addArrangedSubview(
                    ExtensionActionButton(
                        enabled ? L("ext.disable", "Disable") : L("ext.approve", "Approve")
                    ) { [weak self] in
                        var approvals = AppExtensions.approvals()
                        if enabled {
                            approvals.removeValue(forKey: id)
                        } else if let fresh = try? ExtensionHost.load(
                            folder, hostVersion: AppExtensions.hostVersion),
                            fresh == candidate, let approval = try? ExtensionApproval(fresh)
                        {
                            approvals[id] = approval
                        }
                        do {
                            try AppExtensions.save(approvals)
                            self?.didChange()
                        } catch {
                            NSSound.beep()
                        }
                    })
            }
            buttons.addArrangedSubview(
                ExtensionActionButton(L("common.remove", "Remove")) { [weak self] in
                    do {
                        let approvals = AppExtensions.approvals().filter {
                            $0.value.directoryName != folder.lastPathComponent
                        }
                        try AppExtensions.save(approvals)
                        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                    } catch {
                        NSSound.beep()
                    }
                    self?.didChange()
                })
            row.addArrangedSubview(buttons)
            addArrangedSubview(row)
        }
    }

    private func didChange() {
        refresh()
        changed()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.preferredMaxLayoutWidth = 380
        return field
    }
}

@MainActor
private final class ExtensionActionButton: NSButton {
    private let performAction: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        performAction = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { performAction() }
}
