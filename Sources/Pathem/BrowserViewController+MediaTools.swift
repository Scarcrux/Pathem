import AppKit
import PathemEngine

/// Image/PDF/media selection tools: slideshow, sips-based rotate, combine-into-PDF, thumbnail
/// invalidation, markup, trim, and image convert/resize.
@MainActor
extension BrowserViewController {
    /// Full-screen slideshow: 2+ selected images play as-is; otherwise every image in the folder
    /// plays, starting at the one selected (if any). Non-image selections are ignored.
    func startSlideshow() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let selected = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        if selected.count >= 2 {
            slideshow.start(urls: selected)
            return
        }
        let folderImages = pane.entries
            .filter { !$0.isDirectory && Self.isImageName($0.name) }
            .map { pane.currentURL.appendingPathComponent($0.name) }
        guard !folderImages.isEmpty else { NSSound.beep(); return }
        let start = selected.first.flatMap { folderImages.firstIndex(of: $0) } ?? 0
        slideshow.start(urls: folderImages, startAt: start)
    }

    /// Rotate the selected images in place (270 = left, 90 = right) via sips. Not undoable (sips
    /// re-encodes); rotating the other way restores the orientation.
    func rotateSelection(clockwiseDegrees: Int) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            let result = await ImageConverter.rotate(urls, clockwiseDegrees: clockwiseDegrees)
            self.activePane?.reloadIfShowingListing()
            self.invalidateThumbnails(urls)  // the on-disk pixels changed; drop stale thumbnails
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.rotateFailed", "Couldn’t rotate"))
            }
        }
    }

    /// Combine the selected images and PDFs into one new PDF in the folder, then select it.
    func createPDFFromSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter {
            Self.isImageName($0.lastPathComponent) || $0.pathExtension.lowercased() == "pdf"
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor in
            let out = await Task.detached { Self.buildPDF(from: urls, in: folder) }.value
            self.activePane?.reloadIfShowingListing()
            if let out {
                self.activePane?.select(name: out.lastPathComponent)
            } else {
                self.presentInfo(
                    L("bvc.createPDFFailedTitle", "Couldn’t create PDF"),
                    L("bvc.createPDFFailedBody", "None of the selected files could be added to a PDF."))
            }
        }
    }

    /// Drop cached thumbnails for files whose pixels changed on disk, so the grids regenerate them.
    func invalidateThumbnails(_ urls: [URL]) {
        for url in urls { ThumbnailProvider.shared.evict(url) }
    }

    /// Convert each selected video/audio file to `target` (extract audio, or transcode to MP4), off
    /// the main thread, writing a new file beside it (undoable). Reports how many converted or failed.
    func convertMediaSelection(to target: MediaConverter.Target) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter {
            TrimController.trimmableExtensions.contains($0.pathExtension.lowercased())
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        activePane?.flashStatus(L("bvc.convertingMedia", "Converting media…"))
        Task { @MainActor in
            var created: [String] = []
            var failed = 0
            for url in urls {
                do {
                    let out = try await MediaConverter.convert(url, to: target, into: folder)
                    created.append(out.lastPathComponent)
                } catch {
                    failed += 1
                }
            }
            self.activePane?.reloadIfShowingListing()
            if let first = created.first { self.activePane?.select(name: first) }
            if !created.isEmpty {
                self.registerCreatedUndo(
                    names: created, in: folder, actionName: L("bvc.convertMediaAction", "Convert Media"))
                self.activePane?.flashStatus(String(format: L("bvc.convertedMedia", "Converted %d file(s)"), created.count))
            }
            if failed > 0 {
                self.presentInfo(
                    L("bvc.convertMediaFailedTitle", "Couldn’t convert some media"),
                    String(format: L("bvc.convertMediaFailedBody", "%d file(s) couldn’t be converted."), failed))
            }
        }
    }

    /// Strip GPS location from the selected photos (losslessly, in place) after a confirm, since it
    /// edits the originals. Photos with no location are skipped. The "share without leaking where it
    /// was taken" privacy op.
    func removeLocationFromSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.removeLocationTitle", "Remove location from %d photo(s)?"), urls.count)
        alert.informativeText = L(
            "bvc.removeLocationBody",
            "This edits the originals to drop their GPS location, losslessly (no quality loss). Photos without a location are skipped.")
        alert.addButton(withTitle: L("bvc.removeLocationConfirm", "Remove Location"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let removed = await Task.detached { () -> Int in
                var count = 0
                for url in urls where (try? MetadataCleaner.removeLocation(from: url)) == true { count += 1 }
                return count
            }.value
            if removed == 0 {
                self.activePane?.flashStatus(L("bvc.noLocationFound", "No location found in the selected photos"))
            } else {
                self.activePane?.flashStatus(String(format: L("bvc.locationRemoved", "Removed location from %d photo(s)"), removed))
            }
        }
    }

    /// Classify each selected image with Vision and add its top content labels as Finder tags, so the
    /// photos become findable by what's in them (in Pathem and Finder). New tags merge with existing.
    func autoTagSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            let tagged = await Task.detached { () -> Int in
                var count = 0
                for url in urls {
                    let labels = ImageClassifier.classify(url: url)
                    guard !labels.isEmpty else { continue }
                    let existing = FileTags.tags(of: url)
                    let have = Set(existing.map(\.name))
                    let additions = labels.filter { !have.contains($0) }.map { FileTag(name: $0) }
                    guard !additions.isEmpty else { continue }
                    if (try? FileTags.setTags(existing + additions, on: url)) != nil { count += 1 }
                }
                return count
            }.value
            self.activePane?.reloadIfShowingListing()  // reload re-reads tags, so the new dots show
            if tagged == 0 {
                self.presentInfo(
                    L("bvc.autoTagNoneTitle", "No tags added"),
                    L("bvc.autoTagNoneBody", "Vision didn’t find confident content tags for the selected image(s)."))
            } else {
                self.activePane?.flashStatus(String(format: L("bvc.autoTagged", "Tagged %d image(s) by content"), tagged))
            }
        }
    }

    /// Lift the foreground subject of each selected image with Vision, writing a transparent-background
    /// "<name> Cutout.png" beside it (a new file, undoable), then select the first result.
    func removeBackgroundSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor in
            let outcome = await Task.detached { () -> (created: [String], failed: Int) in
                var created: [String] = []
                var failed = 0
                for url in urls {
                    let dest = PhotoLibrary.uniqueURL(
                        in: folder, name: SubjectLift.cutoutName(for: url.lastPathComponent))
                    do {
                        try SubjectLift.removeBackground(from: url, to: dest)
                        created.append(dest.lastPathComponent)
                    } catch {
                        failed += 1
                    }
                }
                return (created, failed)
            }.value
            self.activePane?.reloadIfShowingListing()
            if let first = outcome.created.first { self.activePane?.select(name: first) }
            if !outcome.created.isEmpty {
                self.registerCreatedUndo(
                    names: outcome.created, in: folder, actionName: L("bvc.removeBgAction", "Remove Background"))
            }
            if outcome.failed > 0 {
                self.presentInfo(
                    L("bvc.removeBgFailedTitle", "Couldn’t remove the background"),
                    String(format: L("bvc.removeBgFailedBody", "No subject was found in %d image(s)."), outcome.failed))
            }
        }
    }

    /// Crop the selected image in an interactive window, saving a cropped copy beside it (undoable).
    func cropSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let url = pane.selectedLocalURLs().first, Self.isImageName(url.lastPathComponent),
            let window = view.window
        else { NSSound.beep(); return }
        cropController.onCropped = { [weak self] out in
            self?.activePane?.reloadIfShowingListing()
            self?.activePane?.select(name: out.lastPathComponent)
            self?.registerCreatedUndo(
                names: [out.lastPathComponent], in: out.deletingLastPathComponent(),
                actionName: L("bvc.cropAction", "Crop"))
        }
        cropController.present(url: url, over: window)
    }

    /// Mark up the selected image (freehand annotations), saving a flattened copy.
    func markupSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first,
            Self.isImageName(url.lastPathComponent)
        else { NSSound.beep(); return }
        markupController.onSaved = { [weak self] output in
            self?.activePane?.reloadIfShowingListing()
            self?.activePane?.select(name: output.lastPathComponent)
        }
        markupController.onFailed = { [weak self] message in
            self?.presentInfo(L("markup.failedTitle", "Couldn’t mark up"), message)
        }
        markupController.markup(url)
    }

    /// Trim the selected audio/video file: show the native trim UI, then export the range to a
    /// new "<name> trimmed" file and select it.
    func trimSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first,
            TrimController.trimmableExtensions.contains(url.pathExtension.lowercased())
        else { NSSound.beep(); return }
        trimController.onExported = { [weak self] output in
            self?.activePane?.reloadIfShowingListing()
            self?.activePane?.select(name: output.lastPathComponent)
        }
        trimController.onFailed = { [weak self] message in
            self?.presentInfo(L("trim.failedTitle", "Couldn’t trim"), message)
        }
        trimController.trim(url)
    }

    /// Convert/resize the selected images via sips (out-of-process), after a small dialog
    /// for the target format and maximum pixel size.
    func convertImagesSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }

        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
        formatPopup.addItem(withTitle: L("convert.keepFormat", "Keep format"))
        for format in ImageConverter.Format.allCases { formatPopup.addItem(withTitle: format.rawValue.uppercased()) }
        let sizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        sizeField.placeholderString = L("convert.maxPixels", "Max pixels (optional)")
        func row(_ label: String, _ control: NSView) -> NSStackView {
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: 12)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let stack = NSStackView(views: [name, control])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let stripCheck = NSButton(
            checkboxWithTitle: L("convert.strip", "Strip metadata (EXIF, GPS)"), target: nil, action: nil)
        let accessory = NSStackView(views: [
            row(L("convert.formatLabel", "Format"), formatPopup),
            row(L("convert.sizeLabel", "Max size"), sizeField),
            stripCheck,
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 92)

        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.convertImagesQ", "Convert %d image(s)"), urls.count)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("common.convert", "Convert"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let index = formatPopup.indexOfSelectedItem
            let format = index > 0 ? ImageConverter.Format.allCases[index - 1] : nil
            let maxDim = Int(sizeField.stringValue.trimmingCharacters(in: .whitespaces))
            let options = ImageConverter.Options(
                format: format, maxDimension: maxDim.flatMap { $0 > 0 ? $0 : nil },
                stripMetadata: stripCheck.state == .on)
            guard !options.isNoOp else { return }
            Task { @MainActor in
                let result = await ImageConverter.process(urls, options: options)
                self.activePane?.reloadIfShowingListing()
                if !result.failures.isEmpty {
                    self.presentFailures(result.failures, title: L("bvc.convertFailed", "Couldn’t convert"))
                }
            }
        }
    }
}
