#if DEBUG
import AppKit

/// Only the action receiver is substituted. Key equivalents, modifier masks,
/// enabled state and the native window dispatch stay unchanged. Destructive
/// production callbacks never receive these observation-only Return events.
@MainActor
final class TransientReturnBindingProbe: NSObject {
    var received: [NSButton] = []
    @objc func receive(_ sender: NSButton) { received.append(sender) }

    static func observe(window: NSWindow, buttons: [NSButton], send: () -> Bool)
        -> (accepted: Bool, received: [NSButton], resolved: Bool)
    {
        let probe = TransientReturnBindingProbe()
        let originals = buttons.map { ($0, $0.target, $0.action) }
        for button in buttons {
            button.target = probe
            button.action = #selector(receive(_:))
        }
        let accepted = send()
        if accepted && probe.received.isEmpty {
            let until = Date().addingTimeInterval(1)
            while probe.received.isEmpty && Date() < until {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let resolved = !accepted || !probe.received.isEmpty
        // An accepted but unobserved dispatch has unknown delivery. Retire the
        // fixture with traps still installed, then restore only after it is hidden.
        if !resolved {
            if let parent = window.sheetParent { parent.endSheet(window) }
            window.orderOut(nil)
        }
        for (button, target, action) in originals {
            button.target = target
            button.action = action
        }
        return (accepted, probe.received, resolved)
    }
}

extension TransientSurfaceSample {
    func returnBindingControl() -> Bool {
        let alert = CleanupController.deleteNowAlert(
            totalDescription: "24 B", itemList: "Owned fixture")
        var response: NSApplication.ModalResponse?
        alert.beginSheetModal(for: host) { response = $0 }
        guard settle({ alert.window.isVisible && alert.window.sheetParent === host }) else {
            print(
                "TSAMPLE: BLOCKING-SHEETS "
                    + host.sheets.map { sheet in
                        (sheet.contentView.map {
                            TransientSurfaceChecks.walk($0).compactMap { $0 as? NSTextField }.map {
                                String($0.stringValue.prefix(100))
                            }.filter { !$0.isEmpty }
                        } ?? []).joined(separator: " | ")
                    }.joined(separator: " || "))
            emit(
                "predicate-6-binding", 6, false,
                "control not presented hostVisible=\(host.isVisible) alertVisible=\(alert.window.isVisible) sheetParent=\(alert.window.sheetParent === host) appRunning=\(NSApp.isRunning) hostSheets=\(host.sheets.map { $0.title }) attachedTitle=\(host.attachedSheet?.title ?? "none")"
            )
            return false
        }
        let buttons = alert.buttons
        alert.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let ready = settle {
            alert.window.defaultButtonCell === buttons[0].cell || buttons[0].keyEquivalent == "\r"
        }
        let good = TransientReturnBindingProbe.observe(window: alert.window, buttons: buttons) {
            self.key("\r", window: alert.window)
        }
        let first =
            ready && good.resolved && good.accepted && good.received.count == 1
            && good.received.first === buttons[0] && response == nil
        alert.window.defaultButtonCell = buttons[1].cell as? NSButtonCell
        buttons[0].keyEquivalent = ""
        buttons[1].keyEquivalent = "\r"
        let bad = TransientReturnBindingProbe.observe(window: alert.window, buttons: buttons) {
            self.key("\r", window: alert.window)
        }
        print(
            "TSAMPLE: BINDING-CONTROL ready=\(ready) goodAccepted=\(good.accepted) goodResolved=\(good.resolved) goodIndices=\(good.received.compactMap { received in buttons.firstIndex { $0 === received } }) badAccepted=\(bad.accepted) badIndices=\(bad.received.compactMap { received in buttons.firstIndex { $0 === received } })"
        )
        let discriminates =
            bad.resolved && bad.accepted && bad.received.count == 1
            && bad.received.first === buttons[1] && response == nil
        buttons[1].performClick(nil)
        let cancelled = settle {
            response == .alertSecondButtonReturn && self.host.attachedSheet == nil
        }
        let pass = first && discriminates && cancelled
        emit(
            "predicate-6-binding", 6, pass,
            "originalReturn=\(first) changedDefaultDiscriminates=\(discriminates) callbackWithheld=\(response == .alertSecondButtonReturn) realCancel=\(cancelled)"
        )
        return pass
    }
}
#endif
