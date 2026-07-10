import AppKit
import PathemEngine

/// Out-of-process Swift extensions: the demand-gated `PATHEM_ENABLE_EXTENSIONS` seam. Loads
/// extensions and bridges their contributed commands onto the command registry, invoking a
/// handler out-of-process and rendering its JSON result. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    // MARK: - Extensions (out-of-process, off by default)

    /// Load out-of-process Swift extensions and register their contributed commands on the
    /// same command bus as everything else. This is the demand-gated seam (DESIGN.md Phase 6),
    /// deliberately OFF unless `PATHEM_ENABLE_EXTENSIONS=1`: the FDA host never loads foreign
    /// code in-process, and a shipping build exposes no extension surface until this is
    /// intentionally turned on. Signatures are required unless `PATHEM_EXTENSIONS_UNSIGNED=1`
    /// (local development only).
    func loadExtensionsIfEnabled() {
        let env = ProcessInfo.processInfo.environment
        guard env["PATHEM_ENABLE_EXTENSIONS"] == "1" else { return }
        guard
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Pathem/Extensions"),
            FileManager.default.fileExists(atPath: dir.path)
        else { return }
        let hostVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let policy: ExtensionHost.Policy =
            env["PATHEM_EXTENSIONS_UNSIGNED"] == "1" ? .development : .production
        for ext in ExtensionHost.discover(in: dir, hostVersion: hostVersion, policy: policy) {
            for cmd in ext.manifest.contributes.commands {
                let title = String(format: L("ext.cmdTitle", "%@: %@"), ext.manifest.name, cmd.title)
                commands.register(
                    .init(id: "ext.\(ext.manifest.id).\(cmd.id)", title: title) { [weak self] in
                        self?.runExtensionCommand(ext, handler: cmd.handler, title: title, policy: policy)
                    })
            }
        }
    }

    /// Invoke an extension handler out-of-process with the active pane's context, then show
    /// its result (or error) in a simple alert. A crash, hang, or error in the helper is
    /// isolated by `ExtensionHost` and never touches the host process.
    private func runExtensionCommand(
        _ ext: LoadedExtension, handler: String, title: String, policy: ExtensionHost.Policy
    ) {
        let context = ExtensionProtocol.Context(
            folder: activePane?.currentURL.path,
            selection: activePane?.selectedLocalURLs().map(\.path) ?? [])
        Task { @MainActor in
            do {
                let result = try await ExtensionHost.invoke(
                    ext, handler: handler, context: context, policy: policy)
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
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        }
    }
}
