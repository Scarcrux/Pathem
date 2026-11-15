#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Focused red-first control. The complete three-surface sample is built next.
    func runTransientSurfaceSample(demo: DemoWorkspace.Layout) -> Never {
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_FOCUS"]?.hasPrefix(
            "conflict-") == true
        {
            runTransientConflictProbe(demo: demo)
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(4)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
            return condition()
        }
        let focus = ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_FOCUS"] ?? ""
        guard ["reclaim-return", "reclaim-escape", "reclaim-click"].contains(focus)
        else {
            print("RESULT: FAIL full sample not implemented; focused control required")
            exit(64)
        }
        let home = demo.root.appendingPathComponent("TransientFixtureHome", isDirectory: true)
        let file = home.appendingPathComponent("Library/Caches/go-build/aa/obj")
        let expected = Data("owned-return-key-fixture".utf8)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try expected.write(to: file)
        } catch {
            print("RESULT: FAIL cannot create owned fixture")
            exit(1)
        }
        let cleanup = CleanupController()
        cleanup.debugLoadPlaces(home: home, minimumBytes: 1)
        cleanup.debugCheck(title: "Go build cache")
        guard cleanup.debugDeleteNowEnabled else {
            print("RESULT: FAIL rebuilds fixture not delivered")
            exit(1)
        }
        cleanup.debugTransientPresentDeleteNow()
        let host = cleanup.debugTransientWindow
        guard let alert = cleanup.debugTransientLastAlert,
            settle({
                alert.window.isVisible && alert.window.sheetParent === host
                    && alert.buttons.allSatisfy {
                        $0.window === alert.window && $0.bounds.height > 0
                    }
            }), let content = alert.window.contentView
        else {
            print("RESULT: FAIL confirmation not presented")
            exit(1)
        }
        let sheet = alert.window
        sheet.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let bindingReady = settle {
            alert.buttons.contains { $0.cell === sheet.defaultButtonCell }
        }
        let buttons = alert.buttons
        let defaultButton =
            buttons.first { $0.cell === sheet.defaultButtonCell }
            ?? buttons.first { $0.keyEquivalent == "\r" }
        let expectedCancel = L("common.cancel", "Cancel")
        let namedDefault = defaultButton?.title ?? "missing"
        if let output = ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_OUT"],
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: output).appendingPathComponent("reclaim-return-first.png"))
        }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil,
            characters: focus == "reclaim-escape" ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: focus == "reclaim-escape" ? "\u{1b}" : "\r",
            isARepeat: false, keyCode: focus == "reclaim-escape" ? 53 : 36)!
        print(
            "TRANSIENTSURFACES: INPUT keyWindow=\(sheet.isKeyWindow) bindingReady=\(bindingReady) sameAttached=\(host.attachedSheet === sheet) buttons=\(buttons.map { ($0.title, $0.keyEquivalent.unicodeScalars.map(\.value)) })"
        )
        if focus == "reclaim-click" { buttons[0].performClick(nil) } else { NSApp.sendEvent(event) }
        let delivered = settle { cleanup.debugTransientLastResponse != nil }
        let closed = settle {
            cleanup.debugTransientLastResponse != nil && host.attachedSheet == nil
                && !cleanup.debugTransientDeletePending
        }
        let kept = (try? Data(contentsOf: file)) == expected
        let click = focus == "reclaim-click"
        let expectedResponse: NSApplication.ModalResponse =
            click ? .alertFirstButtonReturn : .alertSecondButtonReturn
        let passed =
            delivered && closed && bindingReady && namedDefault == expectedCancel
            && buttons[0].hasDestructiveAction && buttons[0].keyEquivalent.isEmpty
            && cleanup.debugTransientLastResponse == expectedResponse && kept == !click
            && CleanupController.debugTransientEscapeMonitors == 0
        print(
            "TRANSIENTSURFACES: \(passed ? "PASS" : "FAIL") \(focus) check6 default=\(namedDefault) inputDelivered=\(delivered) response=\(String(describing: cleanup.debugTransientLastResponse?.rawValue)) closed=\(closed) ownedFixturePreserved=\(kept) deleteMarked=\(buttons[0].hasDestructiveAction) activeMonitors=\(CleanupController.debugTransientEscapeMonitors)"
        )
        host.orderOut(nil)
        print("RESULT: \(passed ? "PASS" : "FAIL") (\(passed ? 1 : 0)/1)")
        exit(passed ? 0 : 1)
    }
}
#endif
