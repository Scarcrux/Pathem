#if DEBUG
import AppKit
import CryptoKit
import PDFKit

extension TransientSurfaceSample {
    @MainActor
    final class MarkupLifecycleObservation {
        var prompt = false
        var windowClosed = false
        var quitRequested = false
        var terminating = false
    }

    func runMarkupLifecycle() {
        let mode = environment["PATHEM_TRANSIENT_SURFACES_ONLY"] ?? ""
        guard ["close", "quit"].contains(mode),
            let delegate = NSApp.delegate as? PathemAppDelegate,
            delegate.browser === browser,
            settle({ self.browser.leftTabs.activePane != nil })
        else {
            emit("lifecycle-setup", 0, false, "real delegate/browser or mode missing")
            return
        }
        let directory = output.appendingPathComponent("markup-lifecycle", isDirectory: true)
        let file = directory.appendingPathComponent("owned-unsaved.pdf")
        let control = directory.appendingPathComponent("owned-saved-control.pdf")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            emit("lifecycle-setup", 0, false, "owned directory unavailable")
            return
        }
        for url in [file, control] {
            let document = PDFDocument()
            document.insert(PDFPage(), at: 0)
            guard document.write(to: url) else {
                emit("lifecycle-setup", 0, false, "owned PDF creation failed")
                return
            }
        }
        // Positive control: the same real writer must make an annotation reach disk.
        let controlViewer = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let controlBefore = try? Data(contentsOf: control)
        let controlLoaded = controlViewer.show(control)
        let controlEdited = controlViewer.debugAddUnsavedHighlight() && controlViewer.debugIsEdited
        controlViewer.debugSaveChoice = true
        let controlSaved = controlViewer.offerToSaveIfEdited()
        let controlAfter = try? Data(contentsOf: control)
        let controlAnnotations = PDFDocument(url: control)?.page(at: 0)?.annotations.count ?? 0
        let controlOK =
            controlLoaded && controlEdited && controlSaved
            && controlBefore != controlAfter && controlAnnotations > 0
        emit(
            "predicate-markup-save", 5, controlOK,
            "real writer changed owned bytes and saved annotations=\(controlAnnotations)")
        guard controlOK else { return }

        let countBefore = WindowManager.shared.windowCount
        let target = mode == "close" ? WindowManager.shared.openWindow(start: directory) : browser
        guard let window = target.view.window,
            settle({ target.leftTabs.activePane != nil }), let pane = target.leftTabs.activePane
        else {
            emit("lifecycle-setup", 0, false, "owned browser missing")
            return
        }
        pane.presentViewer(file)
        guard settle({ pane.debugDocumentViewer?.debugShowingPDF == true }),
            let viewer = pane.debugDocumentViewer,
            viewer.debugAddUnsavedHighlight(), viewer.debugIsEdited,
            let before = try? Data(contentsOf: file),
            PDFDocument(url: file)?.page(at: 0)?.annotations.isEmpty == true,
            viewer.debugSaveChoice == nil
        else {
            emit("lifecycle-setup", 0, false, "unsaved markup treatment missing")
            return
        }
        emit(
            "L-\(mode)", 0, true,
            "real PDF edited=true on-disk annotations=0 delegate=PathemAppDelegate")
        if let content = window.contentView { capture(content, key: "L-\(mode)-before") }
        let observation = MarkupLifecycleObservation()
        let persist: @MainActor @Sendable (String) -> Void = { stage in
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            let object: [String: Any] = [
                "mode": mode, "stage": stage, "fixture": file.lastPathComponent,
                "before_sha256": SHA256.hash(data: before).map { String(format: "%02x", $0) }
                    .joined(),
                "after_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
                    .joined(),
                "disk_annotations": PDFDocument(url: file)?.page(at: 0)?.annotations.count ?? -1,
                "edited_before": true, "save_control": controlOK, "prompt_seen": observation.prompt,
                "window_closed": observation.windowClosed,
                "quit_requested": observation.quitRequested,
                "will_terminate": observation.terminating,
                "delegate": String(describing: type(of: delegate)),
            ]
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try data.write(
                    to: directory.appendingPathComponent("witness.json"), options: .atomic)
            } catch { self.emit("lifecycle-setup", 0, false, "cannot write witness") }
        }
        persist("edited")
        // If a guard exists, observe it and abort only this owned fixture's modal.
        // Never select Save/Discard and never allow the probe to wait for user input.
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let modal = NSApp.modalWindow, modal !== window {
                    observation.prompt = true
                    if let content = modal.contentView {
                        self.capture(content, key: "L-\(mode)-prompt")
                    }
                    NSApp.abortModal()
                }
                for sheet in window.sheets {
                    observation.prompt = true
                    if let content = sheet.contentView {
                        self.capture(content, key: "L-\(mode)-prompt")
                    }
                    window.endSheet(sheet, returnCode: .cancel)
                    sheet.orderOut(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        if mode == "close" {
            window.performClose(nil)
            observation.windowClosed =
                !window.isVisible && WindowManager.shared.windowCount == countBefore
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            persist("closed")
            emit(
                "L-close", 4, observation.windowClosed,
                "real performClose removed owned browser window")
            let saved = (PDFDocument(url: file)?.page(at: 0)?.annotations.count ?? 0) > 0
            emit(
                "L-close", 5, observation.prompt || saved,
                "editedBefore=true prompt=\(observation.prompt) saved=\(saved) diskBytesUnchanged=\((try? Data(contentsOf: file)) == before)"
            )
            return
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                observation.terminating = true
                self.checkExternalBoundary("end")
                persist("will-terminate")
                FileHandle.standardOutput.write(Data("TLIFECYCLE: WILL-TERMINATE mode=quit\n".utf8))
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let quit = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                observation.quitRequested = true
                persist("quit-requested")
                FileHandle.standardOutput.write(Data("TLIFECYCLE: QUIT-REQUEST mode=quit\n".utf8))
                NSApp.terminate(nil)
                // A product guard may refuse termination. Stop this private app's
                // loop and return the real outcome instead of forcing a quit.
                persist("quit-refused")
                NSApp.stop(nil)
            }
        }
        RunLoop.main.add(quit, forMode: .default)
        NSApp.run()
        quit.invalidate()
        persist("quit-refused")
        emit(
            "L-quit", 5, observation.prompt && viewer.debugIsEdited,
            "real Quit refused; prompt=\(observation.prompt) editedAfter=\(viewer.debugIsEdited)")
    }
}
#endif
