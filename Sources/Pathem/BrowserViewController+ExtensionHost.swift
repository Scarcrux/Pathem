import AppKit
import PathemEngine

/// Out-of-process Swift extensions: the demand-gated `PATHEM_ENABLE_EXTENSIONS` seam. Loads
/// extensions and bridges their contributed commands onto the command registry, invoking a
/// handler out-of-process and rendering its JSON result. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    // MARK: - Extensions (out-of-process, off by default)

    func loadExtensionsIfEnabled() {
        for command in commands.all where command.id.hasPrefix("ext.") {
            commands.unregister(command.id)
        }
        guard AppExtensions.enabled, ExtensionHost.isolationAvailable,
            let dir = AppExtensions.directory
        else { return }
        let approvals = AppExtensions.approvals()
        for ext in ExtensionHost.discover(in: dir, hostVersion: AppExtensions.hostVersion) {
            guard approvals[ext.manifest.id]?.matches(ext) == true else { continue }
            for cmd in ext.manifest.contributes.commands {
                let title = String(
                    format: L("ext.cmdTitle", "%@: %@"), ext.manifest.name, cmd.title)
                commands.register(
                    .init(id: "ext.\(ext.manifest.id).\(cmd.id)", title: title) { [weak self] in
                        self?.runExtensionCommand(ext, handler: cmd.handler, title: title)
                    })
            }
        }
    }

    /// Invoke an extension handler out-of-process with the active pane's context, then show
    /// its result (or error) in a simple alert. A crash, hang, or error in the helper is
    /// isolated by `ExtensionHost` and never touches the host process.
    private func runExtensionCommand(
        _ ext: LoadedExtension, handler: String, title: String
    ) {
        let context = ExtensionProtocol.Context(
            folder: activePane?.currentURL.path,
            selection: activePane?.selectedLocalURLs().map(\.path) ?? [])
        Task { @MainActor in
            do {
                let result = try await ExtensionHost.invoke(
                    ext, handler: handler, context: context,
                    approval: AppExtensions.approvals()[ext.manifest.id])
                self.presentInfo(title, Self.describe(result))
            } catch {
                self.presentInfo(L("ext.failed", "Extension error"), "\(error)")
            }
        }
    }

    /// Render an extension result as readable text for the info alert.
    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return L("ext.noResult", "Done.")
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return Int(exactly: n).map(String.init) ?? String(n)
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        }
    }
}
