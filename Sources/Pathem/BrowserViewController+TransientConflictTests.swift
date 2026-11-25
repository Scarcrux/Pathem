#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Red-first input proof. It resolves the real prompt but does not execute
    /// a Replace or touch Trash; real Keep Both transfer checks follow the repair.
    func runTransientConflictProbe(demo: DemoWorkspace.Layout) -> Never {
        func settle(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(4)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
            return condition()
        }
        let focus = ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_FOCUS"] ?? ""
        let count = focus.contains("many") ? 2 : 1
        let escape = focus.contains("escape")
        var completed = false
        var answer: FileOperations.ConflictResolution?
        Task { @MainActor in
            answer = await askConflictResolution(conflictCount: count, move: false)
            completed = true
        }
        guard settle({ cursorConfirm.debugPopover?.isShown == true }),
            let popover = cursorConfirm.debugPopover,
            let content = popover.contentViewController?.view,
            let window = content.window
        else {
            print("RESULT: FAIL conflict prompt not delivered")
            exit(1)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let ready = settle {
            LayoutMatrixGeometry.walk(content).compactMap { $0 as? NSButton }
                .contains { $0.keyEquivalent == "\r" }
        }
        let buttons = LayoutMatrixGeometry.walk(content).compactMap { $0 as? NSButton }.sorted {
            $0.tag < $1.tag
        }
        let defaultIndex = buttons.first { $0.keyEquivalent == "\r" }?.tag
        guard !completed, cursorConfirm.debugHasPendingContinuation, popover.isShown else {
            print("RESULT: FAIL instrument prompt closed before input")
            exit(1)
        }
        if let output = ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_OUT"],
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: output).appendingPathComponent("conflict-first.png"))
        }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: escape ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: escape ? "\u{1b}" : "\r", isARepeat: false,
            keyCode: escape ? 53 : 36)!
        let accepted: Bool
        if escape {
            accepted = window.performKeyEquivalent(with: event)
        } else {
            accepted = window.performKeyEquivalent(with: event)
        }
        let delivered = settle { completed }
        let keepBoth: Bool
        if case .keepBoth = answer { keepBoth = true } else { keepBoth = false }
        var passed =
            ready && accepted && delivered && defaultIndex == 1
            && (escape ? answer == nil : keepBoth) && buttons.first?.keyEquivalent.isEmpty == true
            && buttons.map(\.tag) == [0, 1, 2, 3] && cursorConfirm.debugPopover == nil
        print(
            "TRANSIENTSURFACES: \(passed ? "PASS" : "FAIL") \(focus) check6 defaultIndex=\(String(describing: defaultIndex)) dispatch=NSWindow.performKeyEquivalent inputAccepted=\(accepted) inputDelivered=\(delivered) choice=\(String(describing: answer)) keepBoth=\(keepBoth) closed=\(cursorConfirm.debugPopover == nil) operationExecuted=false"
        )
        if passed && focus.contains("transfer") {
            passed = checkTransientKeepBothTransfer(demo: demo, count: count, settle: settle)
        }
        print("RESULT: \(passed ? "PASS" : "FAIL") (\(passed ? 1 : 0)/1)")
        exit(passed ? 0 : 1)
    }
    private func checkTransientKeepBothTransfer(
        demo: DemoWorkspace.Layout, count: Int, settle: (() -> Bool) -> Bool
    ) -> Bool {
        let root = demo.root.appendingPathComponent("TransientConflictFixtures", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let names = (0..<count).map { "clash-\($0).txt" }
            for name in names {
                try Data("INCOMING".utf8).write(to: source.appendingPathComponent(name))
                try Data("ORIGINAL".utf8).write(to: destination.appendingPathComponent(name))
            }
            let oldGuard = transferRunner.debugRefuseReplace
            transferRunner.debugRefuseReplace = true
            let beforeRefusals = transferRunner.debugReplaceRefusals
            var guardOutcome: FileOperations.Outcome?
            transferRunner.run(
                urls: names.map { source.appendingPathComponent($0) }, into: destination,
                move: false, resolution: .replace, over: view.window
            ) { outcome, _, _ in guardOutcome = outcome }
            let guarded =
                guardOutcome?.performed.isEmpty == true
                && guardOutcome?.failures.count == 1
                && transferRunner.debugReplaceRefusals == beforeRefusals + 1
                && names.allSatisfy {
                    (try? Data(contentsOf: destination.appendingPathComponent($0)))
                        == Data("ORIGINAL".utf8)
                }
            guard guarded else {
                transferRunner.debugRefuseReplace = oldGuard
                print("TRANSIENTSURFACES: FAIL replace-safety-control check5")
                return false
            }
            print(
                "TRANSIENTSURFACES: PASS replace-safety-control check5 requestedReplace=true refusedBeforeIO=true refusals=\(transferRunner.debugReplaceRefusals-beforeRefusals) originalsPreserved=true"
            )
            let oldDefault = prefs.conflictDefault
            prefs.conflictDefault = .ask
            var outcome: FileOperations.Outcome?
            resolveThenTransfer(
                urls: names.map { source.appendingPathComponent($0) }, into: destination,
                move: false, conflictCount: count
            ) { outcome = $0 }
            guard settle({ cursorConfirm.debugPopover?.isShown == true }),
                let content = cursorConfirm.debugPopover?.contentViewController?.view,
                let window = content.window
            else {
                prefs.conflictDefault = oldDefault
                transferRunner.debugRefuseReplace = oldGuard
                print("TRANSIENTSURFACES: FAIL real-transfer-prompt-delivery check4")
                return false
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let ready = settle {
                LayoutMatrixGeometry.walk(content).compactMap { $0 as? NSButton }
                    .contains {
                        $0.keyEquivalent == "\r" && $0.window === window && $0.bounds.height > 0
                    }
            }
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            let accepted = ready && window.performKeyEquivalent(with: event)
            let done = settle { outcome != nil }
            prefs.conflictDefault = oldDefault
            transferRunner.debugRefuseReplace = oldGuard
            let originalKept = names.allSatisfy {
                (try? Data(contentsOf: destination.appendingPathComponent($0)))
                    == Data("ORIGINAL".utf8)
            }
            let copies = outcome?.performed ?? []
            let copiesKept =
                copies.count == count
                && copies.allSatisfy {
                    $0.destination
                        != destination.appendingPathComponent($0.source.lastPathComponent)
                        && $0.replacedOriginalTrashed == nil
                        && (try? Data(contentsOf: $0.destination)) == Data("INCOMING".utf8)
                }
            let passed =
                accepted && done && originalKept && copiesKept
                && outcome?.failures.isEmpty == true
                && transferRunner.debugReplaceRefusals == beforeRefusals + 1
            print(
                "TRANSIENTSURFACES: \(passed ? "PASS" : "FAIL") real-keep-both-\(count) check6 inputAccepted=\(accepted) completed=\(done) originalsPreserved=\(originalKept) keptCopies=\(copies.count) copiesVerified=\(copiesKept) accidentalReplaceRefused=\(transferRunner.debugReplaceRefusals-beforeRefusals-1)"
            )
            return passed
        } catch {
            print("TRANSIENTSURFACES: FAIL owned-conflict-fixture check5")
            return false
        }
    }
}
#endif
