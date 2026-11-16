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
    var reportedSearchInternals = Set<String>()
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
    func trace(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
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
    func singleSurfacePresentation(before: [Int], expected: NSWindow, alert: NSAlert?) -> Bool {
        // Never exempt framework windows globally: they must be newly visible,
        // geometrically bound to this very NSAlert, and there may be only one.
        let companions =
            alert?.window === expected
            ? NSApp.windows.filter { candidate in
                candidate.isVisible && !before.contains(candidate.windowNumber)
                    && TransientSurfaceChecks.alertGlassCompanion(
                        alertClass: String(describing: type(of: expected)),
                        alertFrame: expected.frame,
                        candidateClass: String(describing: type(of: candidate)),
                        candidateFrame: candidate.frame,
                        candidateSheetParent: candidate.sheetParent?.windowNumber)
            } : []
        for companion in companions {
            trace(
                "TSAMPLE: FRAMEWORK-COMPANION expected=\(expected.windowNumber) number=\(companion.windowNumber) class=\(type(of: companion)) frame=\(companion.frame)"
            )
        }
        return TransientSurfaceChecks.singlePresentation(
            before: before, after: windows(),
            expected: expected.windowNumber, companions: companions.map(\.windowNumber))
    }
    func windowDetails() -> String {
        NSApp.windows.filter(\.isVisible).map { window in
            "number=\(window.windowNumber) class=\(type(of: window)) frame=\(window.frame) parent=\(String(describing: window.sheetParent?.windowNumber))"
        }.joined(separator: "; ")
    }
    func snapshot(_ directory: URL) -> [String: Data] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [:] }
        var files: [String: Data] = [:]
        let base = directory.standardizedFileURL.path
        // DirectoryEnumerator omitted the deliberately dangling link in the
        // native counterexample. Enumerate names, then lstat each entry, so
        // adding a symlink is observable without ever following its target.
        var urls = [directory]
        var index = 0
        while index < urls.count {
            let url = urls[index]
            index += 1
            let path = url.standardizedFileURL.path
            guard path == base || path.hasPrefix(base + "/") else { continue }
            let key = Data(String(path.dropFirst(base.count)).utf8).base64EncodedString()
            guard let attributes = try? fm.attributesOfItem(atPath: path) else {
                files[key + ":unreadable"] = Data()
                continue
            }
            let type = attributes[.type] as? FileAttributeType
            files[key + ":type"] = Data((type?.rawValue ?? "unknown").utf8)
            files[key + ":permissions"] = Data(
                String(describing: attributes[.posixPermissions]).utf8)
            if type == .typeSymbolicLink {
                files[key + ":link"] = (try? fm.destinationOfSymbolicLink(atPath: path)).map {
                    Data($0.utf8)
                }
                continue  // Never read a symlink target outside our fixture.
            }
            guard
                url.resolvingSymlinksInPath().standardizedFileURL.path
                    == directory.resolvingSymlinksInPath().standardizedFileURL.path
                    || url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                        directory.resolvingSymlinksInPath().standardizedFileURL.path + "/")
            else { continue }
            if type == .typeDirectory {
                if let names = try? fm.contentsOfDirectory(atPath: path) {
                    urls += names.map { url.appendingPathComponent($0) }
                } else {
                    files[key + ":unreadable-directory"] = Data()
                }
            }
            if type == .typeRegular { files[key + ":bytes"] = try? Data(contentsOf: url) }
            for name in ExtendedAttributes.names(of: url) {
                files[key + ":xattr:" + name] = ExtendedAttributes.value(name, of: url)
            }
        }
        return files
    }
    func delivered(_ name: String, _ detail: String) {
        if injected.insert(name).inserted { trace("TSAMPLE: INJECT \(name) \(detail)") }
    }
    func recordFramework(
        _ content: NSView, alert: NSAlert?, cell: String, systemAccessory: NSView? = nil,
        systemPanel: Bool = false
    ) {
        let nativeSearch = TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }
            .filter { TransientSurfaceChecks.nativeSearchButton($0) }
        if !nativeSearch.isEmpty && reportedSearchInternals.insert(cell).inserted {
            trace(
                "TSAMPLE: INFO cell=\(cell) frameworkSearchButtonCells=\(nativeSearch.count) exactNSSearchFieldCellIdentity=true"
            )
        }
        let noInk = TransientSurfaceChecks.nondrawingAlertNodes(content, alert: alert)
        if !noInk.isEmpty && frameworkInfo[cell] == nil {
            trace(
                "TSAMPLE: INFO cell=\(cell) nondrawingAlertNodes=\(noInk.map { String(describing: type(of: $0)) }) exactEmptyInformativeLabel=true"
            )
        }
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
        if environment["PATHEM_TRANSIENT_GEOMETRY_DIAGNOSTIC"] == "1" {
            for issue in issues {
                trace(
                    "TSAMPLE: GEOMETRY-ISSUE cell=\(cell) phase=\(phase) check=\(issue.number) detail=\(issue.detail)"
                )
            }
            for field in TransientSurfaceChecks.walk(content).compactMap({ $0 as? NSTextField })
            where field.stringValue.isEmpty {
                trace(
                    "TSAMPLE: EMPTY-FIELD cell=\(cell) phase=\(phase) \(TransientSurfaceChecks.diagnostic(field)) children=\(TransientSurfaceChecks.walk(field).dropFirst().map { String(describing: type(of: $0)) + ":" + String(describing: $0.frame) })"
                )
                if phase == "cycle0-mounted", let alert,
                    field.superview === content, alert.informativeText.isEmpty,
                    !field.isEditable, !field.isBordered, !field.drawsBackground
                {
                    func pixels() -> Data? {
                        guard
                            let bitmap = content.bitmapImageRepForCachingDisplay(
                                in: content.bounds),
                            !bitmap.isPlanar,
                            let context = NSGraphicsContext(bitmapImageRep: bitmap)
                        else { return nil }
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        content.effectiveAppearance.performAsCurrentDrawingAppearance {
                            NSColor.windowBackgroundColor.setFill()
                            NSBezierPath(rect: content.bounds).fill()
                        }
                        NSGraphicsContext.restoreGraphicsState()
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        guard let bytes = bitmap.bitmapData else { return nil }
                        let row = (bitmap.pixelsWide * bitmap.bitsPerPixel + 7) / 8
                        var data = Data()
                        for y in 0..<bitmap.pixelsHigh {
                            data.append(bytes.advanced(by: y * bitmap.bytesPerRow), count: row)
                        }
                        return data
                    }
                    func frames() -> [ObjectIdentifier: NSRect] {
                        Dictionary(
                            uniqueKeysWithValues: TransientSurfaceChecks.walk(content).map {
                                (ObjectIdentifier($0), $0.frame)
                            })
                    }
                    let originalHidden = field.isHidden
                    let beforeFrames = frames()
                    let responder = content.window?.firstResponder.map(ObjectIdentifier.init)
                    let a = pixels()
                    let b = pixels()
                    field.isHidden = true
                    let hidden = pixels()
                    let hiddenFrames = frames()
                    field.isHidden = originalHidden
                    let restored = pixels()
                    let inkControl = NSTextField(labelWithString: "VISIBLE INK CONTROL")
                    inkControl.frame = NSRect(x: 12, y: 12, width: 220, height: 20)
                    content.addSubview(inkControl)
                    let paintedControl = pixels()
                    inkControl.isHidden = true
                    let hiddenControl = pixels()
                    inkControl.removeFromSuperview()
                    let inkDetected =
                        paintedControl != nil && hiddenControl != nil
                        && paintedControl != hiddenControl
                    let stable = a != nil && a == b && a == restored
                    trace(
                        "TSAMPLE: EMPTY-INK cell=\(cell) stable=\(stable) hiddenEquals=\(a != nil && a == hidden) framesUnchanged=\(beforeFrames == hiddenFrames && beforeFrames == frames()) responderUnchanged=\(responder == content.window?.firstResponder.map(ObjectIdentifier.init)) inkControlDetected=\(inkDetected) bytes=\(a?.count ?? 0)"
                    )
                }

            }
            capture(content, key: cell + "-diagnostic-" + phase)
            content.layoutSubtreeIfNeeded()
            let painted = TransientSurfaceChecks.geometry(
                content, alert: alert, systemAccessory: systemAccessory, systemPanel: systemPanel)
            trace(
                "TSAMPLE: GEOMETRY-PAINT cell=\(cell) phase=\(phase) before=\(issues.count) after=\(painted.count) firstAfter=\(painted.first?.detail ?? "none")"
            )
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
    func visibleGeometryControls() -> Bool {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = NSClipView(frame: NSRect(x: 10, y: 10, width: 100, height: 50))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        clip.documentView = document
        root.addSubview(clip)
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 20))
        document.addSubview(cell)
        let field = TransientSurfaceChecks.VisibilityLabel(labelWithString: "123")
        field.translatesAutoresizingMaskIntoConstraints = true
        field.font = .systemFont(ofSize: 11)
        field.frame = NSRect(x: 2, y: 3, width: 60, height: 14)
        field.injectedVisibleRect = NSRect(x: -8, y: -3, width: 635, height: 20)
        cell.addSubview(field)
        let oversizedRegionPasses =
            TransientSurfaceChecks.geometry(root).isEmpty
            && TransientSurfaceChecks.boundedVisibleRect(field) == field.bounds
        // A fully offscreen sibling must not create false overlap.
        let offscreen = TransientSurfaceChecks.VisibilityLabel(labelWithString: "offscreen")
        offscreen.translatesAutoresizingMaskIntoConstraints = true
        offscreen.frame = NSRect(x: 2, y: 3, width: 60, height: 14)
        offscreen.injectedVisibleRect = .zero
        cell.addSubview(offscreen)
        let offscreenPasses = TransientSurfaceChecks.geometry(root).isEmpty
        offscreen.removeFromSuperview()
        field.frame.size.width = 0
        field.injectedVisibleRect = .zero
        let collapsedTextFails = TransientSurfaceChecks.geometry(root).contains { $0.number == 1 }
        let emptyRoot = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let spacer = NSView(frame: NSRect(x: 10, y: 10, width: 0, height: 20))
        emptyRoot.addSubview(spacer)
        let emptyText = NSTextField(labelWithString: "")
        emptyText.frame = NSRect(x: 10, y: 40, width: 0, height: 16)
        emptyRoot.addSubview(emptyText)
        let emptyLeavesPass = TransientSurfaceChecks.geometry(emptyRoot).isEmpty
        let child = NSTextField(labelWithString: "must remain visible")
        child.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        spacer.addSubview(child)
        let collapsedContainerFails = TransientSurfaceChecks.geometry(emptyRoot).contains {
            $0.number == 1
        }
        child.removeFromSuperview()
        emptyText.stringValue = "must remain visible"
        let nonemptyTextFails = TransientSurfaceChecks.geometry(emptyRoot).contains {
            $0.number == 1
        }
        // The native popup frame extends beyond its 20 pt row by the SDK's
        // alignment insets; a displaced alignment rectangle must still fail.
        field.removeFromSuperview()
        let inset = TransientSurfaceChecks.InsetControl(frame: .zero)
        inset.frame = inset.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 64, height: 20))
        cell.addSubview(inset)
        let insideIssues = TransientSurfaceChecks.geometry(root)
        let alignedInsidePasses = insideIssues.isEmpty
        inset.frame.origin.x += 30
        let alignedOutsideFails = TransientSurfaceChecks.geometry(root).contains { $0.number == 1 }
        trace(
            "TSAMPLE: VIEWPORT-CONTROLS oversized=\(oversizedRegionPasses) offscreen=\(offscreenPasses) collapsed=\(collapsedTextFails) empty=\(emptyLeavesPass) container=\(collapsedContainerFails) nonempty=\(nonemptyTextFails) alignedInside=\(alignedInsidePasses) alignedOutside=\(alignedOutsideFails) insideIssues=\(insideIssues.map(\.detail))"
        )
        return oversizedRegionPasses && offscreenPasses && collapsedTextFails
            && emptyLeavesPass && collapsedContainerFails && nonemptyTextFails
            && alignedInsidePasses && alignedOutsideFails
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
            validScroll.isEmpty && invalidScroll.contains { $0.number == 1 }
                && visibleGeometryControls(),
            "bounded visible ink, offscreen siblings and empty leaves pass; collapsed content and viewport overflow fail"
        )
        let tooltipRoot = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let icon = NSButton(frame: NSRect(x: 10, y: 10, width: 48, height: 48))
        icon.title = ""
        icon.image = NSImage(size: NSSize(width: 16, height: 16))
        icon.imagePosition = .imageOnly
        icon.toolTip = "Owned action"
        tooltipRoot.addSubview(icon)
        let tooltipGood = TransientSurfaceChecks.geometry(tooltipRoot)
        icon.toolTip = nil
        let tooltipBad = TransientSurfaceChecks.geometry(tooltipRoot)
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        let nativeIcon = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let customIcon = NSButton(frame: NSRect(x: 30, y: 0, width: 24, height: 24))
        customIcon.title = ""
        customIcon.image = icon.image
        customIcon.imagePosition = .imageOnly
        if let searchCell = search.cell as? NSSearchFieldCell,
            let nativeCell = searchCell.searchButtonCell
        {
            nativeIcon.cell = nativeCell
        }
        search.addSubview(nativeIcon)
        search.addSubview(customIcon)
        let searchScopeOK =
            TransientSurfaceChecks.nativeSearchButton(nativeIcon)
            && !TransientSurfaceChecks.nativeSearchButton(customIcon)
            && TransientSurfaceChecks.missingIconTooltips(search).contains { $0 === customIcon }
            && !TransientSurfaceChecks.missingIconTooltips(search).contains { $0 === nativeIcon }
        emit(
            "predicate-1-tooltip", 1,
            searchScopeOK && tooltipGood.isEmpty
                && tooltipBad.contains { $0.detail.hasPrefix("icon-only control has no tooltip") }
                && tooltipBad.allSatisfy { $0.number == 1 },
            "app-supplied icon-only control: tooltip present passes; missing tooltip fails geometry"
        )
        let popupRoot = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let popup = NSPopUpButton(frame: NSRect(x: 10, y: 20, width: 140, height: 26))
        popup.addItems(withTitles: ["Short", String(repeating: "Long selected title ", count: 8)])
        popup.selectItem(at: 0)
        popupRoot.addSubview(popup)
        let popupShort = TransientSurfaceChecks.geometry(popupRoot)
        let shortMeasurement = TransientSurfaceChecks.popupTitleMeasurement(popup)
        popup.selectItem(at: 1)
        let popupLong = TransientSurfaceChecks.geometry(popupRoot)
        let longMeasurement = TransientSurfaceChecks.popupTitleMeasurement(popup)
        let ordinaryRoot = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let ordinary = NSButton(frame: NSRect(x: 10, y: 20, width: 20, height: 26))
        ordinary.title = "OK"
        ordinary.keyEquivalent = "\r"
        ordinaryRoot.addSubview(ordinary)
        let ordinaryBad = TransientSurfaceChecks.geometry(ordinaryRoot)
        emit(
            "predicate-1-popup", 1,
            popupShort.isEmpty && shortMeasurement.fits && !longMeasurement.fits
                && popupLong.contains { $0.detail.hasPrefix("popup displayed title=") }
                && popupLong.allSatisfy { $0.number == 1 }
                && ordinaryBad.contains { $0.detail.hasPrefix("button title clipped:") }
                && ordinaryBad.allSatisfy { $0.number == 1 },
            "short=[\(shortMeasurement.detail)] long=[\(longMeasurement.detail)] ordinaryClipped=\(ordinaryBad.contains { $0.detail.hasPrefix("button title clipped:") })"
        )
        let blankAlert = NSAlert()
        blankAlert.messageText = "Empty native informative field control"
        blankAlert.informativeText = ""
        blankAlert.addButton(withTitle: "OK")
        blankAlert.accessoryView = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 44))
        blankAlert.layout()
        let blankContent = blankAlert.window.contentView!
        capture(blankContent, key: "predicate-empty-alert-layout")
        trace(
            "TSAMPLE: EMPTY-CONTROL root=\(type(of: blankContent)) fields=\(TransientSurfaceChecks.walk(blankContent).compactMap { $0 as? NSTextField }.filter { $0.stringValue.isEmpty }.map { TransientSurfaceChecks.diagnostic($0) + " helper=" + String(describing: $0.subviews.map { String(describing: type(of: $0)) }) })"
        )
        let blankNodes = TransientSurfaceChecks.nondrawingAlertNodes(
            blankContent, alert: blankAlert)
        let blankGood = TransientSurfaceChecks.geometry(blankContent, alert: blankAlert)
        var textChecked = false
        var placeholderChecked = false
        var childChecked = false
        if let field = blankNodes.first as? NSTextField {
            field.stringValue = "Visible label must remain measured"
            textChecked =
                TransientSurfaceChecks.nondrawingAlertNodes(blankContent, alert: blankAlert).isEmpty
                && TransientSurfaceChecks.geometry(blankContent, alert: blankAlert).contains {
                    $0.number == 1
                }
            field.stringValue = ""
            field.placeholderString = "Visible placeholder must remain measured"
            placeholderChecked =
                TransientSurfaceChecks.nondrawingAlertNodes(blankContent, alert: blankAlert).isEmpty
                && TransientSurfaceChecks.geometry(blankContent, alert: blankAlert).contains {
                    $0.number == 1
                }
            field.placeholderString = nil
            let unexpected = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            field.addSubview(unexpected)
            childChecked =
                TransientSurfaceChecks.nondrawingAlertNodes(blankContent, alert: blankAlert).isEmpty
                && TransientSurfaceChecks.geometry(blankContent, alert: blankAlert).contains {
                    $0.number == 1
                }
            unexpected.removeFromSuperview()
        }
        let ownedRoot = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        let ownedInput = NSTextField(string: "")
        ownedInput.frame = NSRect(x: 10, y: 10, width: 0, height: 20)
        ownedRoot.addSubview(ownedInput)
        let ownedChecked =
            TransientSurfaceChecks.nondrawingAlertNodes(ownedRoot, alert: blankAlert).isEmpty
            && TransientSurfaceChecks.geometry(ownedRoot).contains {
                $0.number == 1
            }
        emit(
            "predicate-1-empty-alert", 1,
            blankNodes.count == 2 && !blankGood.contains { $0.number == 1 }
                && textChecked && placeholderChecked && childChecked && ownedChecked,
            "exactNativeNodes=\(blankNodes.map { String(describing: type(of: $0)) }) blankPass=\(!blankGood.contains { $0.number == 1 }) textChecked=\(textChecked) placeholderChecked=\(placeholderChecked) extraChildChecked=\(childChecked) collapsedOwnedChecked=\(ownedChecked)"
        )
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
        trace(
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
        emit(
            "predicate-4-presentation", 4,
            TransientSurfaceChecks.presentation(.sheet, parent: 10, host: 10, popoverAnchor: nil)
                && !TransientSurfaceChecks.presentation(
                    .sheet, parent: nil, host: 10, popoverAnchor: nil)
                && !TransientSurfaceChecks.presentation(
                    .window, parent: 10, host: 10, popoverAnchor: nil)
                && TransientSurfaceChecks.presentation(
                    .popover, parent: nil, host: 10, popoverAnchor: 10)
                && !TransientSurfaceChecks.presentation(
                    .popover, parent: nil, host: 10, popoverAnchor: 20)
                && TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [10, 20], expected: 20)
                && !TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [10, 20, 30], expected: 20)
                && !TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [20], expected: 20)
                && TransientSurfaceChecks.alertGlassCompanion(
                    alertClass: "_NSAlertPanel",
                    alertFrame: NSRect(x: 100, y: 100, width: 400, height: 200),
                    candidateClass: "_NSGlassEffectWindow",
                    candidateFrame: NSRect(x: 25, y: 25, width: 550, height: 350),
                    candidateSheetParent: nil)
                && !TransientSurfaceChecks.alertGlassCompanion(
                    alertClass: "_NSPopoverWindow",
                    alertFrame: NSRect(x: 100, y: 100, width: 400, height: 200),
                    candidateClass: "_NSGlassEffectWindow",
                    candidateFrame: NSRect(x: 25, y: 25, width: 550, height: 350),
                    candidateSheetParent: nil)
                && !TransientSurfaceChecks.alertGlassCompanion(
                    alertClass: "_NSAlertPanel",
                    alertFrame: NSRect(x: 100, y: 100, width: 400, height: 200),
                    candidateClass: "NSWindow",
                    candidateFrame: NSRect(x: 25, y: 25, width: 550, height: 350),
                    candidateSheetParent: nil)
                && !TransientSurfaceChecks.alertGlassCompanion(
                    alertClass: "_NSAlertPanel",
                    alertFrame: NSRect(x: 100, y: 100, width: 400, height: 200),
                    candidateClass: "_NSOtherEffectWindow",
                    candidateFrame: NSRect(x: 25, y: 25, width: 550, height: 350),
                    candidateSheetParent: nil)
                && !TransientSurfaceChecks.alertGlassCompanion(
                    alertClass: "_NSAlertPanel",
                    alertFrame: NSRect(x: 100, y: 100, width: 400, height: 200),
                    candidateClass: "_NSGlassEffectWindow",
                    candidateFrame: NSRect(x: 25, y: 25, width: 550, height: 350),
                    candidateSheetParent: 10)
                && !TransientSurfaceChecks.alertGlassCompanion(
                    alertClass: "_NSAlertPanel",
                    alertFrame: NSRect(x: 100, y: 100, width: 400, height: 200),
                    candidateClass: "_NSGlassEffectWindow",
                    candidateFrame: NSRect(x: 26, y: 25, width: 550, height: 350),
                    candidateSheetParent: nil)
                && TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [10, 20, 30], expected: 20, companions: [30])
                && !TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [10, 20, 30, 40], expected: 20, companions: [30])
                && !TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [10, 20, 30, 40], expected: 20, companions: [30, 40])
                && !TransientSurfaceChecks.singlePresentation(
                    before: [10, 30], after: [10, 20, 30], expected: 20, companions: [30])
                && !TransientSurfaceChecks.singlePresentation(
                    before: [10], after: [10, 20, 20], expected: 20)
                && !TransientSurfaceChecks.noAccumulation(before: [10], after: [10, 30]),
            "presentation ownership; one measured NSAlert glass companion only; unknown and leaked windows still fail"
        )
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
                && FileOpening.debugRequests?.isEmpty == true
                && !Self.externalBoundaryAllowed(network: 1, devices: 0)
                && !Self.externalBoundaryAllowed(network: 0, devices: 1),
            "networkStarts=\(SharedDiscovery.debugTransientStarts) deviceStarts=\(DeviceWatcher.debugTransientStarts) networkSkips=\(SharedDiscovery.debugTransientSkips) deviceSkips=\(DeviceWatcher.debugTransientSkips) openerRequests=\(FileOpening.debugRequests?.count ?? -1)"
        )
    }

    func run() -> Never {
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            trace("RESULT: FAIL cannot create owned sample root")
            exit(1)
        }
        // The documented opener-suite interception also protects a Cancel
        // regression from opening another app or changing LaunchServices.
        FileOpening.debugRequests = []
        FileOpening.open(root.appendingPathComponent("owned-open-control"), with: nil)
        let openerControl = FileOpening.debugRequests?.count == 1
        FileOpening.debugRequests = []
        emit(
            "predicate-file-opening", 0, openerControl,
            "documented opener interception delivered; unexpected requests remain red")
        host.contentView!.addSubview(focus)
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(focus)
        trace(
            "TSAMPLE: START language=\(language) preferred=\(Locale.preferredLanguages) cancel=\(L("common.cancel", "missing")) pilot=\(pilot) injection=\(injection)"
        )
        if full { trace("TSAMPLE: DOMAIN " + (Bundle.main.bundleIdentifier ?? "missing")) }
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
        if injection == "clean", environment["PATHEM_TRANSIENT_SURFACES_SET"] != "core" {
            if full { classBFull() } else { classBSample() }
        }
        finish(started)
    }
    func finish(_ started: Date) -> Never {
        checkExternalBoundary("end")
        focus.removeFromSuperview()
        for (cell, info) in frameworkInfo.sorted(by: { $0.key < $1.key }) {
            trace(
                "TSAMPLE: INFO cell=\(cell) frameworkAmbiguousMax=\(info.count) classes=\(info.names.sorted())"
            )
        }
        trace(
            "TSAMPLE: SUMMARY cells=\(cells.filter { !$0.hasPrefix("predicate-") }.count) predicates=\(predicateCount) checks=\(results.count) failures=\(results.filter { !$0 }.count) seconds=\(Date().timeIntervalSince(started))"
        )
        trace(
            "RESULT: \(results.allSatisfy { $0 } ? "PASS" : "FAIL") (\(results.filter { $0 }.count)/\(results.count))"
        )
        exit(results.allSatisfy { $0 } ? 0 : 1)
    }

    func runSurface(
        _ kind: String, cell: String, name: String, plain: (() -> NSAlert)? = nil,
        cancelAt: Int? = nil, responseBase: Int = 1000
    ) {
        var coreSites: [String] = []
        if kind != "plain" {
            let coreRules: [String: [(String, String)]] = [
                "rename": [("BrowserViewController+Rename.swift", "presentSheet")],
                "reclaim": [("CleanupController.swift", "presentDeleteNowAlert")],
                "conflict": [
                    ("BrowserViewController+Transfers.swift", "ask"),
                    ("CursorConfirm.swift", "show"),
                ],
            ]
            let rules = coreRules[kind] ?? []
            coreSites = policy.keys.filter { key in
                (policy[key]?["class"] as? String == "A")
                    && rules.contains { file, method in
                        key.hasPrefix("Sources/Pathem/" + file + ":") && key.hasSuffix(":" + method)
                    }
            }
            guard coreSites.count == rules.count && !rules.isEmpty else {
                emit("core-contract", 0, false, "reviewed core production sites missing")
                return
            }
        }
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
            let sourceKey = Data(("/" + name).utf8).base64EncodedString()
            guard beforeFiles[sourceKey + ":bytes"] == Data("owned sample bytes".utf8),
                beforeFiles.keys.filter({ $0.hasSuffix(":type") }).count == 2
            else {
                emit(cell, 5, false, "fixture snapshot not delivered: \(beforeFiles.keys.sorted())")
                return
            }
            host.makeFirstResponder(focus)
            let responder = host.firstResponder.map(ObjectIdentifier.init)
            let beforeWindows = windows()
            trace("TSAMPLE: WINDOWS before cell=\(cell) cycle=\(cycle) \(windowDetails())")
            var returnAction = (kind != "plain" || full) && cycle == 1
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
                trace(
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
            if kind != "plain" {
                for site in coreSites.sorted() {
                    trace("TSAMPLE: CORE-SITE cell=\(cell) cycle=\(cycle) site=\(site)")
                }
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let nativeReady = settle {
                let actions =
                    alert?.buttons
                    ?? TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }
                return
                    (kind == "plain" && !actions.isEmpty
                    && actions.allSatisfy { $0.bounds.width > 0 })
                    || actions.contains {
                        $0.bounds.width > 0
                            && ($0.keyEquivalent == "\r" || $0.cell === window.defaultButtonCell)
                    }
            }
            let buttons =
                alert?.buttons
                ?? TransientSurfaceChecks.walk(content).compactMap { $0 as? NSButton }.sorted {
                    $0.tag < $1.tag
                }
            trace(
                "TSAMPLE: WINDOWS presented cell=\(cell) cycle=\(cycle) expected=\(window.windowNumber) before=\(beforeWindows) after=\(windows()) \(windowDetails())"
            )
            let ownership =
                kind == "conflict"
                ? browser.cursorConfirm.debugAnchorWindowNumber : window.sheetParent?.windowNumber
            emit(
                cell, 4,
                singleSurfacePresentation(before: beforeWindows, expected: window, alert: alert)
                    && TransientSurfaceChecks.ownership(
                        actual: ownership, expected: host.windowNumber)
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
            var defaultOK =
                nativeReady
                && TransientSurfaceChecks.defaultAction(
                    actual: actualDefault, expected: expectedDefault,
                    destructive: kind == "reclaim", intended: intended)
            if kind == "plain", actualDefault == nil {
                // A Cancel-first native alert can deliberately have no default.
                // Prove Return is inert, then use its real Cancel instead of
                // manufacturing an expected default and cascading timeout reds.
                defaultOK = nativeReady
                if returnAction {
                    defaultOK =
                        defaultOK && !key("\r", window: window) && !completed && window.isVisible
                    returnAction = false
                }
            }
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
            var expectedFiles = beforeFiles
            if expectedMutation {
                expectedFiles = beforeFiles.filter { !$0.key.hasPrefix(sourceKey + ":") }
                if kind == "rename" {
                    let destinationKey = Data("/confirmed.txt".utf8).base64EncodedString()
                    for (key, value) in beforeFiles where key.hasPrefix(sourceKey + ":") {
                        expectedFiles[destinationKey + key.dropFirst(sourceKey.count)] = value
                    }
                }
            }
            let stateOK = TransientSurfaceChecks.unchanged(expectedFiles, afterFiles)
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
            trace(
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
                trace(
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
