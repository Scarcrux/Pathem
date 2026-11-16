#if DEBUG
import AppKit
import ObjectiveC

/// A DEBUG-only observation hook, installed only by the isolated full-surface harness.
/// It records the actual alert supplied by production, then forwards its original
/// presentation unchanged. No completion, response or presentation style is replaced.
@MainActor
enum TransientPresentationProbe {
    static var current: NSAlert?
    private static var installed = false
    static func install() -> Bool {
        guard !installed else { return true }
        guard
            let original = class_getInstanceMethod(
                NSAlert.self,
                #selector(NSAlert.beginSheetModal(for:completionHandler:))),
            let witness = class_getInstanceMethod(
                NSAlert.self,
                #selector(NSAlert.pathemTransientSheet(for:completionHandler:)))
        else { return false }
        method_exchangeImplementations(original, witness)
        installed = true
        return true
    }
    static func uninstall() {
        guard installed,
            let original = class_getInstanceMethod(
                NSAlert.self,
                #selector(NSAlert.beginSheetModal(for:completionHandler:))),
            let witness = class_getInstanceMethod(
                NSAlert.self,
                #selector(NSAlert.pathemTransientSheet(for:completionHandler:)))
        else { return }
        method_exchangeImplementations(original, witness)
        installed = false
        current = nil
    }
}

extension NSAlert {
    @objc func pathemTransientSheet(
        for window: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
    ) {
        TransientPresentationProbe.current = self
        pathemTransientSheet(for: window, completionHandler: handler)
    }
}
#endif
