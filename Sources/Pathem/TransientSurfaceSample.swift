#if DEBUG
import AppKit
import PathemEngine

/// Unit 1 only. Each destructive action is restricted to a file created by this runner.
@MainActor
final class TransientSurfaceSample {
    let browser: BrowserViewController
    let root: URL
    let host: NSWindow
    let output: URL
    let policy: [String: [String: Any]]
    let focus = NSTextView(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
    let environment = ProcessInfo.processInfo.environment
    var results: [Bool] = []
    var captured = Set<String>()
    var injected = Set<String>()
    var cells = Set<String>()
    var predicateCount = 0
    var requestedSize = NSSize.zero
    var requestedAppearance: NSAppearance.Name?
    var frameworkInfo: [String: (count: Int, names: Set<String>)] = [:]
    var language: String { environment["PATHEM_TRANSIENT_SURFACES_LANGUAGE"] ?? "missing" }
    var full: Bool { environment["PATHEM_TRANSIENT_SURFACES_FULL"] == "1" }
    var pilot: Bool { environment["PATHEM_TRANSIENT_SURFACES_PILOT"] == "1" }
    var injection: String { environment["PATHEM_TRANSIENT_SURFACES_INJECT"] ?? "clean" }

    init?(browser: BrowserViewController, demo: DemoWorkspace.Layout) {
        guard let host = browser.view.window,
            let path = ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_OUT"],
            let inventory = ProcessInfo.processInfo.environment[
                "PATHEM_TRANSIENT_SURFACES_INVENTORY"],
            let data = try? Data(contentsOf: URL(fileURLWithPath: inventory)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let policy = json["sites"] as? [String: [String: Any]]
        else { return nil }
        self.browser = browser
        self.host = host
        self.root = demo.root.appendingPathComponent("TransientSampleFixtures", isDirectory: true)
        self.output = URL(fileURLWithPath: path, isDirectory: true)
        self.policy = policy
    }

    func settle(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return condition()
    }
    func emit(
        _ cell: String, _ number: Int, _ passed: Bool, _ detail: String = "", content: NSView? = nil
    ) {
        results.append(passed)
        cells.insert(cell)
        FileHandle.standardOutput.write(
            Data(
                "TSAMPLE: \(passed ? "PASS" : "FAIL") cell=\(cell) check=\(number) \(detail)\n".utf8
            ))
        if !passed, let content { capture(content, key: cell + "-check\(number)") }
    }
    func capture(_ content: NSView, key: String) {
        guard captured.insert(key).inserted,
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: content.bounds).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        content.cacheDisplay(in: content.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            do { try data.write(to: output.appendingPathComponent(key + ".png")) } catch {
                emit(key, 1, false, "render write failed")
            }
        }
    }
    func windows() -> [Int] {
        NSApp.windows.filter(\.isVisible).map(\.windowNumber).sorted()
    }
    func snapshot(_ directory: URL) -> [String: Data] {
        let fm = FileManager.default
        guard
            let entries = fm.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }
        var files: [String: Data] = [:]
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in entries {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                files[String(path.dropFirst(base.count))] = try? Data(contentsOf: url)
            }
        }
        return files
    }
    func delivered(_ name: String, _ detail: String) {
        if injected.insert(name).inserted { print("TSAMPLE: INJECT \(name) \(detail)") }
    }
    func recordFramework(
        _ content: NSView, alert: NSAlert?, cell: String, systemAccessory: NSView? = nil,
        systemPanel: Bool = false
    ) {
        let nodes = TransientSurfaceChecks.ambiguity(
            content, alert: alert, systemAccessory: systemAccessory, systemPanel: systemPanel
        ).framework
        let old = frameworkInfo[cell] ?? (0, [])
        frameworkInfo[cell] = (
            max(old.count, nodes.count),
            old.names.union(nodes.map { String(describing: type(of: $0)) })
        )
    }
    func inspect(
        _ content: NSView, alert: NSAlert?, cell: String, phase: String, sheet: Bool,
        presented: Bool, systemAccessory: NSView? = nil, systemPanel: Bool = false
    ) {
        recordFramework(
            content, alert: alert, cell: cell, systemAccessory: systemAccessory,
            systemPanel: systemPanel)
        let issues = TransientSurfaceChecks.geometry(
            content, alert: alert, systemAccessory: systemAccessory, systemPanel: systemPanel)
        for number in [1, 3] {
            let failures = issues.filter { $0.number == number }
            emit(
                cell, number, failures.isEmpty,
                "phase=\(phase) count=\(failures.count) first=\(failures.first?.detail ?? "none")",
                content: content)
        }
        let screen = host.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = content.window?.frame.size ?? content.bounds.size
        // Structural-only B cells check measured extents, not an unpresented window origin.
        let frame = presented ? content.window!.frame : NSRect(origin: screen.origin, size: size)
        emit(
            cell, 2,
            TransientSurfaceChecks.fits(
                frame: frame, screen: screen, sheet: sheet, host: host.contentLayoutRect.size)
                && host.contentLayoutRect.size == requestedSize,
            "phase=\(phase) frame=\(frame) host=\(host.contentLayoutRect.size) screen=\(screen) presented=\(presented) requestedHost=\(requestedSize)",
            content: content)
    }
    func key(_ character: String, window: NSWindow) -> Bool {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: character == "\r" ? 36 : 53)
        else { return false }
        return window.performKeyEquivalent(with: event)
    }
    func predicateControls() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        view.addSubview(field)
        func control(_ number: Int, _ good: Bool, _ bad: Bool, _ isolated: Bool = true) {
            let passed = good && !bad && isolated
            predicateCount += 1
            emit(
                "predicate-\(number)", number, passed,
                "positive=\(good) negative=\(bad) isolated=\(isolated)")
        }
        let before = TransientSurfaceChecks.geometry(view)
        field.frame.origin.x = 180
        let clipped = TransientSurfaceChecks.geometry(view)
        control(
            1, before.isEmpty, !clipped.contains { $0.number == 1 },
            clipped.allSatisfy { $0.number == 1 })
        field.frame.origin.x = 10
        let scrollRoot = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = NSClipView(frame: NSRect(x: 10, y: 10, width: 100, height: 50))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        clip.documentView = document
        scrollRoot.addSubview(clip)
        let validScroll = TransientSurfaceChecks.geometry(scrollRoot)
        clip.frame.origin.x = 180
        let invalidScroll = TransientSurfaceChecks.geometry(scrollRoot)
        emit(
            "predicate-1-viewport", 1,
            validScroll.isEmpty && invalidScroll.contains { $0.number == 1 },
            "scrolling content clipped; viewport itself must still fit")
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        control(
            2,
            TransientSurfaceChecks.fits(
                frame: NSRect(x: 10, y: 10, width: 200, height: 100), screen: screen, sheet: true,
                host: NSSize(width: 720, height: 420)),
            TransientSurfaceChecks.fits(
                frame: NSRect(x: 10, y: 10, width: 800, height: 100), screen: screen, sheet: true,
                host: NSSize(width: 720, height: 420)))
        let native = NSAlert()
        native.messageText = "Native ambiguity control"
        native.informativeText = "Native layout control body"
        native.addButton(withTitle: "OK")
        native.layout()
        let nativeContent = native.window.contentView!
        let nativeIssues = TransientSurfaceChecks.geometry(nativeContent, alert: native)
        recordFramework(nativeContent, alert: native, cell: "predicate-3-native")
        let frameworkReported = !TransientSurfaceChecks.ambiguity(nativeContent, alert: native)
            .framework.isEmpty
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 70))
        let ambiguous = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
        ambiguous.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(ambiguous)
        NSLayoutConstraint.activate([
            ambiguous.widthAnchor.constraint(equalToConstant: 50),
            ambiguous.heightAnchor.constraint(equalToConstant: 30),
        ])
        native.accessoryView = accessory
        native.layout()
        nativeContent.layoutSubtreeIfNeeded()
        // Leave x/y under-constrained, but choose a visible valid solution so
        // this control changes only ambiguity rather than also clipping a view.
        ambiguous.setFrameOrigin(NSPoint(x: 10, y: 10))
        let ambiguityDelivered = ambiguous.hasAmbiguousLayout
        let ambiguousIssues = TransientSurfaceChecks.geometry(nativeContent, alert: native)
        print(
            "TSAMPLE: CONTROL3 appAmbiguous=\(ambiguityDelivered) before=\(nativeIssues.map { ($0.number, $0.detail) }) after=\(ambiguousIssues.map { ($0.number, $0.detail) })"
        )
        control(
            3, !nativeIssues.contains { $0.number == 3 } && frameworkReported,
            !ambiguousIssues.contains { $0.number == 3 },
            ambiguityDelivered && ambiguousIssues.allSatisfy { $0.number == 3 })
        let panelGood = TransientSurfaceChecks.geometry(nativeContent, systemPanel: true)
        let panelBad = TransientSurfaceChecks.geometry(
            nativeContent, systemAccessory: accessory, systemPanel: true)
        recordFramework(nativeContent, alert: nil, cell: "predicate-3-system", systemPanel: true)
        emit(
            "predicate-3-system", 3,
            !panelGood.contains { $0.number == 3 } && panelBad.contains { $0.number == 3 },
            "native panel internals INFO; deliberately ambiguous app accessory stays red")
        control(
            4, TransientSurfaceChecks.ownership(actual: 10, expected: 10),
            TransientSurfaceChecks.ownership(actual: 20, expected: 10))
        view.appearance = NSAppearance(named: .aqua)
        let correctAppearance = TransientSurfaceChecks.appearance(view, expected: .aqua)
        view.appearance = NSAppearance(named: .darkAqua)
        emit(
            "predicate-4-appearance", 4,
            correctAppearance && !TransientSurfaceChecks.appearance(view, expected: .aqua),
            "effective appearance must match the requested treatment")
        let data = ["fixture": Data("original".utf8)]
        control(
            5, TransientSurfaceChecks.unchanged(data, data),
            TransientSurfaceChecks.unchanged(data, ["fixture": Data("changed".utf8)]))
        control(
            6,
            TransientSurfaceChecks.defaultAction(
                actual: 1, expected: 1, destructive: false, intended: false, delivered: 1),
            TransientSurfaceChecks.defaultAction(
                actual: 0, expected: 1, destructive: true, intended: false, delivered: 0))
        let identity = ObjectIdentifier(focus)
        control(
            7,
            TransientSurfaceChecks.dismissed(
                pending: false, visible: false, responderBefore: identity, responderAfter: identity),
            TransientSurfaceChecks.dismissed(
                pending: true, visible: true, responderBefore: identity, responderAfter: identity))
        control(
            8, TransientSurfaceChecks.noAccumulation(before: [1], after: [1]),
            TransientSurfaceChecks.noAccumulation(before: [1], after: [1, 2]))
        let aliasBefore = [1]
        let aliasAfter = [1, 1]
        emit(
            "predicate-8-multiplicity", 8,
            Set(aliasBefore) == Set(aliasAfter)
                && !TransientSurfaceChecks.noAccumulation(before: aliasBefore, after: aliasAfter),
            "literal window count must not collapse repeated numeric identifiers")
    }

    static func externalBoundaryAllowed(network: Int, devices: Int) -> Bool {
        network == 0 && devices == 0
    }

    func checkExternalBoundary(_ phase: String) {
        let noCalls = Self.externalBoundaryAllowed(
            network: SharedDiscovery.debugTransientStarts,
            devices: DeviceWatcher.debugTransientStarts)
        emit(
            "predicate-external-" + phase, 0,
            noCalls && SharedDiscovery.debugTransientSkips > 0
                && DeviceWatcher.debugTransientSkips > 0
                && !Self.externalBoundaryAllowed(network: 1, devices: 0)
                && !Self.externalBoundaryAllowed(network: 0, devices: 1),
            "networkStarts=\(SharedDiscovery.debugTransientStarts) deviceStarts=\(DeviceWatcher.debugTransientStarts) networkSkips=\(SharedDiscovery.debugTransientSkips) deviceSkips=\(DeviceWatcher.debugTransientSkips)"
        )
    }

    func run() -> Never {
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("RESULT: FAIL cannot create owned sample root")
            exit(1)
        }
        host.contentView!.addSubview(focus)
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(focus)
        print(
            "TSAMPLE: START language=\(language) preferred=\(Locale.preferredLanguages) cancel=\(L("common.cancel", "missing")) pilot=\(pilot) injection=\(injection)"
        )
        if full { print("TSAMPLE: DOMAIN " + (Bundle.main.bundleIdentifier ?? "missing")) }
        checkExternalBoundary("start")
        predicateControls()
        guard results.allSatisfy({ $0 }) else { finish(started) }
        if !["b", "mounts", "factories", "lifecycle"].contains(
            environment["PATHEM_TRANSIENT_SURFACES_SET"] ?? ""),
            ["de", "ja"].contains(language)
        {
            let appearances: [NSAppearance.Name] = pilot ? [.aqua] : [.aqua, .darkAqua]
            let sizes: [NSSize] =
                pilot
                ? [NSSize(width: 720, height: 420)]
                : [NSSize(width: 720, height: 420), NSSize(width: 1100, height: 700)]
            for appearance in appearances {
                requestedAppearance = appearance
                host.appearance = NSAppearance(named: appearance)
                for size in sizes {
                    requestedSize = size
                    host.setContentSize(size)
                    for kind in ["rename", "reclaim", "conflict"] {
                        for long in (kind == "rename" && !pilot ? [false, true] : [false]) {
                            let name =
                                long ? String(repeating: "n", count: 251) + ".txt" : "fixture.txt"
                            let cell =
                                "A-\(kind)-\(language)-\(appearance == .aqua ? "light" : "dark")-\(Int(size.width))-\(long ? "long255" : "short")"
                            runSurface(kind, cell: cell, name: name)
                        }
                    }
                }
            }
        }
        if full, environment["PATHEM_TRANSIENT_SURFACES_SET"] == "mounts" {
            guard TransientPresentationProbe.install() else {
                emit("mount-hook", 0, false, "observation hook missing")
                finish(started)
            }
            runFullMounts()
            TransientPresentationProbe.uninstall()
            finish(started)
        }
        if full, environment["PATHEM_TRANSIENT_SURFACES_SET"] == "lifecycle" {
            runMarkupLifecycle()
            finish(started)
        }
        if full, environment["PATHEM_TRANSIENT_SURFACES_SET"] == "factories" {
            runFullFactories()
            finish(started)
        }
        if injection == "clean" { if full { classBFull() } else { classBSample() } }
        finish(started)
    }
    func finish(_ started: Date) -> Never {
        checkExternalBoundary("end")
        focus.removeFromSuperview()
        for (cell, info) in frameworkInfo.sorted(by: { $0.key < $1.key }) {
            print(
                "TSAMPLE: INFO cell=\(cell) frameworkAmbiguousMax=\(info.count) classes=\(info.names.sorted())"
            )
        }
        print(
            "TSAMPLE: SUMMARY cells=\(cells.filter { !$0.hasPrefix("predicate-") }.count) predicates=\(predicateCount) checks=\(results.count) failures=\(results.filter { !$0 }.count) seconds=\(Date().timeIntervalSince(started))"
        )
        print(
            "RESULT: \(results.allSatisfy { $0 } ? "PASS" : "FAIL") (\(results.filter { $0 }.count)/\(results.count))"
        )
        exit(results.allSatisfy { $0 } ? 0 : 1)
    }

    func runSurface(
        _ kind: String, cell: String, name: String, plain: (() -> NSAlert)? = nil,
        cancelAt: Int? = nil, responseBase: Int = 1000
    ) {
        for cycle in 0..<3 {
            let fm = FileManager.default
            let directory = root.appendingPathComponent(cell + "-\(cycle)", isDirectory: true)
            let file = directory.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("owned sample bytes".utf8).write(to: file)
            } catch {
                emit(cell, 5, false, "cannot create fixture")
                return
            }
            let beforeFiles = snapshot(directory)
            guard let originalBytes = beforeFiles["/" + name], beforeFiles.count == 1 else {
                emit(cell, 5, false, "fixture snapshot not delivered: \(beforeFiles.keys.sorted())")
                return
            }
            host.makeFirstResponder(focus)
            let responder = host.firstResponder.map(ObjectIdentifier.init)
            let beforeWindows = windows()
            let returnAction = (kind != "plain" || full) && cycle == 1
            let escape = kind == "conflict" && cycle == 2
            var completed = false
            var response: NSApplication.ModalResponse?
            var conflictAnswer: FileOperations.ConflictResolution?
            var dialog: RenameDialogController?
            var alert: NSAlert?
            var popover: NSPopover?
            if kind == "conflict" {
                Task { @MainActor in
                    conflictAnswer = await browser.askConflictResolution(
                        conflictCount: 2, move: false)
                    completed = true
                }
                _ = settle { self.browser.cursorConfirm.debugPopover?.isShown == true }
                popover = browser.cursorConfirm.debugPopover
            } else {
                if kind == "rename" {
                    dialog = RenameDialogController(
                        name: name, url: file, dataless: false, offerSuggestions: true,
                        generateAutomatically: false)
                    alert = dialog!.alert
                } else if kind == "reclaim" {
                    let sizeText = ByteCountFormatter.string(fromByteCount: 24, countStyle: .file)
                    let place =
                        ReclaimCatalog.places.first { $0.id == "go-build" }?.name
                        ?? "Go build cache"
                    alert = CleanupController.deleteNowAlert(
                        totalDescription: sizeText, itemList: "• " + place + " (" + sizeText + ")")
                } else {
                    alert = plain?()
                }
                guard let alert else {
                    emit(cell, 4, false, "missing factory")
                    return
                }
                alert.window.appearance = host.appearance
                let completion: (NSApplication.ModalResponse) -> Void = { value in
                    response = value
                    if kind == "reclaim" && value == .alertFirstButtonReturn {
                        try? fm.removeItem(at: file)
                    }
                    if kind == "rename" && value == .alertFirstButtonReturn,
                        let edited = dialog?.field.stringValue
                    {
                        try? fm.moveItem(at: file, to: directory.appendingPathComponent(edited))
                    }
                    if kind == "rename" && value == .alertSecondButtonReturn
                        && self.injection == "cancel-commits-edit" && cycle == 0
                        && !self.injected.contains("cancel-commits-edit")
                    {
                        do {
                            try fm.moveItem(
                                at: file,
                                to: directory.appendingPathComponent("cancel-committed.txt"))
                            self.delivered(
                                "cancel-commits-edit",
                                "real Cancel completion renamed owned fixture")
                        } catch { self.emit(cell, 5, false, "cancel injection mutation failed") }
                    }
                    completed = true
                }
                if kind == "reclaim" {
                    CleanupController.presentDeleteNowAlert(
                        alert, for: host, completion: completion)
                } else if kind == "rename" || cell.contains("extension-confirm") {
                    Task { @MainActor in completion(await self.browser.presentSheet(alert)) }
                } else {
                    alert.beginSheetModal(for: host, completionHandler: completion)
                }
            }
            let presented = settle {
                if let alert {
                    return alert.window.isVisible && alert.window.sheetParent === self.host
                }
                return popover?.isShown == true
                    && popover?.contentViewController?.view.window != nil
            }
            guard presented,
                let content = alert?.window.contentView ?? popover?.contentViewController?.view,
                let window = content.window
            else {
                print(
                    "TSAMPLE: PRESENT-DIAGNOSTIC cell=\(cell) hostVisible=\(host.isVisible) attached=\(host.attachedSheet?.title ?? "none") alertVisible=\(alert?.window.isVisible ?? false) alertSheet=\(alert?.window.sheetParent === host) popShown=\(popover?.isShown ?? false) popWindow=\(popover?.contentViewController?.view.window != nil) completed=\(completed) keys=\(alert?.buttons.map { ($0.title, $0.keyEquivalent.unicodeScalars.map(\.value), $0.bounds) } ?? [])"
                )
                emit(cell, 4, false, "native presentation not delivered")
                if let alert, host.attachedSheet === alert.window {
                    host.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
                    alert.window.orderOut(nil)
                }
                popover?.performClose(nil)
                _ = settle { completed }
                return
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let nativeReady = settle {
                let actions =
                    alert?.buttons
                    ?? TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }
                return actions.contains {
                    $0.bounds.width > 0
                        && ($0.keyEquivalent == "\r" || $0.cell === window.defaultButtonCell)
                }
            }
            let buttons =
                alert?.buttons
                ?? TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }.sorted {
                    $0.tag < $1.tag
                }
            let ownership =
                kind == "conflict"
                ? browser.cursorConfirm.debugAnchorWindowNumber : window.sheetParent?.windowNumber
            emit(
                cell, 4,
                TransientSurfaceChecks.ownership(actual: ownership, expected: host.windowNumber)
                    && TransientSurfaceChecks.appearance(content, expected: requestedAppearance),
                "cycle=\(cycle) actualHost=\(String(describing: ownership)) expected=\(host.windowNumber) appearance=\(String(describing: content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))) requestedAppearance=\(String(describing: requestedAppearance))",
                content: content)
            inspect(
                content, alert: alert, cell: cell, phase: "cycle\(cycle)-initial",
                sheet: kind != "conflict", presented: true)
            if cycle == 0 { capture(content, key: "surface-" + kind + "-" + language) }
            if let suggestion = dialog?.suggestion {
                suggestion.debugDeliver(
                    String(repeating: "long suggested name ", count: 8), ext: "txt")
                content.layoutSubtreeIfNeeded()
                inspect(
                    content, alert: alert, cell: cell, phase: "cycle\(cycle)-suggestion",
                    sheet: true, presented: true)
                suggestion.debugFail()
                inspect(
                    content, alert: alert, cell: cell, phase: "cycle\(cycle)-failure", sheet: true,
                    presented: true)
            }
            if returnAction, let dialog {
                dialog.field.stringValue = "confirmed.txt"
                (dialog.field.currentEditor() as? NSTextView)?.string = "confirmed.txt"
                content.layoutSubtreeIfNeeded()
                inspect(
                    content, alert: alert, cell: cell, phase: "cycle\(cycle)-typed", sheet: true,
                    presented: true)
            }
            let actualDefault: Int? =
                kind == "conflict"
                ? buttons.first { $0.keyEquivalent == "\r" }?.tag
                : buttons.firstIndex {
                    $0.cell === window.defaultButtonCell || $0.keyEquivalent == "\r"
                }
            let expectedDefault = kind == "conflict" ? 1 : 0
            let intended =
                kind == "reclaim"
                && policy.contains {
                    $0.key.contains("presentDeleteNowAlert")
                        && $0.value["default_destructive_intended"] as? Bool == true
                        && ($0.value["owner_decision"] as? [String: Any])?["quote"] as? String
                            == "Go back to the original: Return deletes."
                }
            let defaultOK =
                nativeReady
                && TransientSurfaceChecks.defaultAction(
                    actual: actualDefault, expected: expectedDefault,
                    destructive: kind == "reclaim", intended: intended)
            let suppress =
                kind == "conflict" && cycle == 0
                && environment["PATHEM_TRANSIENT_INJECT_DISMISS_FAILURE"] != nil
                && !injected.contains("dismiss-failure")
            var keyAccepted: Bool?
            if suppress {
                delivered("dismiss-failure", "real popover dismiss request withheld")
            } else if returnAction || escape {
                keyAccepted = key(
                    escape ? "\u{1b}" : "\r", window: window)
            } else {
                let cancelIndex =
                    cancelAt
                    ?? (kind == "plain" && cell.contains("extension-confirm")
                        ? 0 : buttons.count - 1)
                if buttons.indices.contains(cancelIndex) { buttons[cancelIndex].performClick(nil) }
            }
            let ended = settle { completed }
            var actualResponseIndex: Int?
            if let response {
                actualResponseIndex =
                    response.rawValue - responseBase
            }
            if kind == "conflict", returnAction {
                if case .keepBoth = conflictAnswer {
                    actualResponseIndex = 1
                } else {
                    actualResponseIndex = -1
                }
            }
            if kind != "plain" || full {
                emit(
                    cell, 6,
                    defaultOK
                        && (!returnAction
                            || keyAccepted == true && ended
                                && actualResponseIndex == expectedDefault),
                    "cycle=\(cycle) default=\(String(describing: actualDefault)) intended=\(intended) actualReturn=\(String(describing: actualResponseIndex)) keyAccepted=\(String(describing: keyAccepted)) completed=\(ended)",
                    content: content)
            }
            let afterFiles = snapshot(directory)
            let expectedMutation = returnAction && ["rename", "reclaim"].contains(kind)
            let cancelIndex =
                cancelAt
                ?? (kind == "plain" && cell.contains("extension-confirm") ? 0 : buttons.count - 1)
            let cancelConfirmed =
                kind == "conflict" ? conflictAnswer == nil : actualResponseIndex == cancelIndex
            let stateOK =
                expectedMutation
                ? (kind == "reclaim"
                    ? afterFiles.isEmpty : afterFiles == ["/confirmed.txt": originalBytes])
                : TransientSurfaceChecks.unchanged(beforeFiles, afterFiles)
            let fileOK = ended && (returnAction || cancelConfirmed) && stateOK
            emit(
                cell, 5, fileOK,
                "cycle=\(cycle) cancelled=\(!returnAction) fixtureBefore=\(beforeFiles.keys.sorted()) fixtureAfter=\(afterFiles.keys.sorted())",
                content: content)
            _ = settle { self.host.attachedSheet == nil && !(popover?.isShown ?? false) }
            let afterResponder = host.firstResponder.map(ObjectIdentifier.init)
            let dismissalOK = TransientSurfaceChecks.dismissed(
                pending: !completed || host.attachedSheet != nil
                    || (kind == "conflict" && browser.cursorConfirm.debugHasPendingContinuation),
                visible: window.isVisible || (popover?.isShown ?? false),
                responderBefore: responder, responderAfter: afterResponder)
            emit(
                cell, 7, dismissalOK,
                "cycle=\(cycle) completed=\(completed) visible=\(window.isVisible) attached=\(host.attachedSheet != nil) responderRestored=\(responder == afterResponder)",
                content: content)
            // Restore deliberately suppressed dismissal only after check 7 records the red.
            if suppress {
                popover?.performClose(nil)
                _ = settle { completed && self.browser.cursorConfirm.debugPopover == nil }
            }
            dialog?.cancel()
            var leak: NSWindow?
            if injection == "leaked-window" && cycle == 0 && kind == "rename"
                && !injected.contains("leaked-window")
            {
                let stray = NSWindow(
                    contentRect: NSRect(
                        x: host.frame.minX + 20, y: host.frame.minY + 20, width: 180, height: 80),
                    styleMask: [.titled], backing: .buffered, defer: false)
                stray.isReleasedWhenClosed = false
                stray.appearance = host.appearance
                let label = NSTextField(labelWithString: "Injected stray window")
                label.frame = NSRect(x: 8, y: 24, width: 164, height: 20)
                stray.contentView?.addSubview(label)
                stray.orderFront(nil)
                if let content = stray.contentView {
                    capture(content, key: cell + "-actual-stray-window")
                }
                leak = stray
                delivered("leaked-window", "actual extra visible window=\(stray.windowNumber)")
            }
            let afterWindows = windows()
            emit(
                cell, 8,
                TransientSurfaceChecks.noAccumulation(before: beforeWindows, after: afterWindows),
                "cycle=\(cycle) visibleBefore=\(beforeWindows.sorted()) visibleAfter=\(afterWindows.sorted())",
                content: content)
            leak?.orderOut(nil)
            if !completed {
                host.endSheet(window, returnCode: .alertSecondButtonReturn)
                window.orderOut(nil)
                popover?.performClose(nil)
            }
        }
    }

    func plainAlert(_ sample: [String: Any]) -> NSAlert {
        let alert = NSAlert()
        let id = sample["id"] as! String
        let key = sample["message_key"] as! String
        alert.messageText = L(key, "MISSING:" + key)
        let info = sample["informative_keys"] as! [String]
        func text(_ index: Int) -> String { L(info[index], "MISSING:" + info[index]) }
        switch id {
        case "automation-result", "tag-failure":
            alert.informativeText = String(format: text(0), 999999)
        case "sync-result":
            alert.informativeText =
                String(format: text(0), 999999, 999999) + String(format: text(1), 999999)
                + String(format: text(2), 999999)
        case "mirror-result":
            alert.informativeText =
                String(format: text(0), 999999, 999999) + String(format: text(1), 999999)
        case "toggle-failure":
            alert.informativeText =
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                    userInfo: [
                        NSFilePathErrorKey: "/fixture/" + String(repeating: "n", count: 251)
                            + ".txt"
                    ]
                ).localizedDescription
            alert.alertStyle = .warning
        case "path-suggestion":
            let path =
                "/"
                + Array(repeating: String(repeating: "p", count: 255), count: 4).joined(
                    separator: "/")
            let suggestion = URL(fileURLWithPath: String(path.dropLast()) + "s")
            PaneController.configurePathSuggestion(alert, raw: path, suggestion: suggestion)
            emit(
                "path-full-text", 5,
                alert.window.contentView?.toolTip == String(format: text(0), path, suggestion.path),
                "full stress input remains reachable; navigation URL is unmodified")
        default: alert.informativeText = info.isEmpty ? "" : text(0)
        }
        for key in sample["button_keys"] as! [String] {
            alert.addButton(withTitle: L(key, "MISSING:" + key))
        }
        return alert
    }
    func ownedPathProof(_ sample: [String: Any], cell: String) {
        let fm = FileManager.default
        var directory = root.appendingPathComponent("OwnedPathProof", isDirectory: true)
        for index in 0..<3 {
            directory.appendPathComponent(
                String(index) + String(repeating: "d", count: 179), isDirectory: true)
        }
        let candidate = directory.appendingPathComponent(
            String(repeating: "n", count: 176) + ".txt")
        let bytes = Data("owned path proof".utf8)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: candidate)
            let actual = try Data(contentsOf: candidate)
            guard actual == bytes else {
                emit(cell, 5, false, "owned path proof not delivered")
                return
            }
            let raw = String(candidate.path.dropLast()) + "x"
            let alert = plainAlert(sample)
            PaneController.configurePathSuggestion(alert, raw: raw, suggestion: candidate)
            alert.layout()
            guard let content = alert.window.contentView else {
                emit(cell, 1, false, "owned-path native content missing")
                return
            }
            print(
                "TSAMPLE: OWNED-PATH bytes=\(candidate.path.utf8.count) componentMax=180 candidateExists=\(fm.fileExists(atPath: candidate.path))"
            )
            inspect(
                content, alert: alert, cell: cell, phase: "existing-owned-path", sheet: true,
                presented: false)
            capture(content, key: "owned-path-proof-" + language)
        } catch { emit(cell, 5, false, "owned-path fixture cannot be created") }
    }
    func classBSample() {
        requestedAppearance = nil
        let samples = policy.values.compactMap { $0["sample"] as? [String: Any] }.sorted {
            ($0["id"] as! String) < ($1["id"] as! String)
        }
        emit(
            "B-contract", 4,
            samples.count == 10
                && samples.filter { $0["behavior_sample"] as? Bool == true }.count == 3,
            "ten alerts; three lifecycle candidates")
        for size
            in (pilot
            ? [NSSize(width: 720, height: 420)]
            : [NSSize(width: 720, height: 420), NSSize(width: 1100, height: 700)])
        {
            requestedSize = size
            host.setContentSize(size)
            for sample in samples {
                let id = sample["id"] as! String
                let alert = plainAlert(sample)
                alert.layout()
                guard let content = alert.window.contentView else {
                    emit("B-" + id, 1, false, "missing native content")
                    continue
                }
                let cell = "B-\(id)-\(language)-\(Int(size.width))"
                print(
                    "TSAMPLE: CONTENT cell=\(cell) messageKey=\(sample["message_key"] ?? "missing") messageChars=\(alert.messageText.count) informativeChars=\(alert.informativeText.count)"
                )
                inspect(
                    content, alert: alert, cell: cell, phase: "structural-only", sheet: true,
                    presented: false)
                if id == "path-suggestion", language == "de", size.width == 720 {
                    ownedPathProof(sample, cell: cell)
                }
                if language == "de", sample["behavior_sample"] as? Bool == true {
                    runSurface(
                        "plain", cell: cell + "-lifecycle", name: "fixture.txt",
                        plain: { self.plainAlert(sample) })
                }
            }
        }
    }
}
#endif
