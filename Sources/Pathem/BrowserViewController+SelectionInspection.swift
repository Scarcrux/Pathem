import AppKit
import PathemEngine

// Non-destructive commands that read or annotate the active selection: copy paths/names/
// checksums, verify a checksum, duplicate in place, bulk-set attributes, diff two files, show
// extended attributes, strip quarantine, and set the Finder comment. Split out of
// BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Copy the selection's paths (POSIX or file://) to the clipboard, one per line.
    func copyPaths(asURL: Bool) {
        guard let pane = activePane else { NSSound.beep(); return }
        let lines: [String]
        if pane.isRemote {
            lines = pane.selectedPathStrings()  // server-side paths; a file:// URL doesn't apply
        } else {
            lines = pane.selectedLocalURLs().map { asURL ? $0.absoluteString : $0.path }
        }
        guard !lines.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        flashCopied(count: lines.count, kind: asURL ? L("flash.url", "URL") : L("flash.path", "path"))
    }

    /// Hash the selected file(s) off the main thread and copy the digests (one per
    /// line; "hash  name" when multiple).
    func copyChecksums(_ algorithm: FileHasher.Algorithm = .sha256) {
        let files = (activePane?.selectedLocalURLs() ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        guard !files.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            let lines = await Task.detached { () -> [String] in
                files.compactMap { url in
                    guard let hash = try? FileHasher.hash(url, algorithm: algorithm) else { return nil }
                    return files.count == 1 ? hash : "\(hash)  \(url.lastPathComponent)"
                }
            }.value
            guard !lines.isEmpty else {
                self.presentInfo(
                    L("checksum.failedTitle", "Couldn’t hash the selection"),
                    L("checksum.failedBody", "None of the selected files could be read. They may be unreadable without Full Disk Access, or they may have been removed."))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            self.flashCopied(count: lines.count, kind: L("flash.checksum", "checksum"))
        }
    }

    /// Hash the one selected file and compare it to a checksum on the clipboard
    /// (algorithm inferred from the clipboard digest's length).
    func verifyChecksum() {
        guard let url = (activePane?.selectedLocalURLs() ?? []).first,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { NSSound.beep(); return }
        let expected = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        // Only the lengths we can actually compute (MD5/SHA-1/SHA-256); accepting a
        // SHA-512-length digest and silently comparing it as SHA-256 would never match.
        let algorithm: FileHasher.Algorithm
        switch expected.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil ? expected.count : -1 {
        case 32: algorithm = .md5
        case 40: algorithm = .sha1
        case 64: algorithm = .sha256
        default:
            presentChecksumResult(
                title: L("bvc.unsupportedChecksum", "Unsupported checksum"),
                text: L("bvc.unsupportedChecksumBody", "Copy a hex MD5, SHA-1, or SHA-256 to the clipboard first."))
            return
        }
        Task { @MainActor in
            let actual = await Task.detached { try? FileHasher.hash(url, algorithm: algorithm) }.value
            guard let actual else {
                presentChecksumResult(title: L("bvc.couldntReadFile", "Couldn’t read the file"), text: url.lastPathComponent)
                return
            }
            let match = actual == expected
            presentChecksumResult(
                title: match
                    ? String(format: L("bvc.checksumMatches", "%@ matches ✓"), algorithm.label)
                    : String(format: L("bvc.checksumNoMatch", "%@ does NOT match"), algorithm.label),
                text: "\(url.lastPathComponent)\n\n"
                    + String(format: L("bvc.checksumExpectedActual", "Expected: %@\nActual:   %@"), expected, actual))
        }
    }

    /// Duplicate the selected items in place ("<name> copy"), undoable.
    func duplicateSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let folder = pane.currentURL
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        var created: [String] = []
        var failures: [FileOperations.Failure] = []
        for name in names {
            do { created.append(try FileOperations.duplicate(name, in: folder)) } catch {
                failures.append(.init(name: name, reason: error.localizedDescription))
            }
        }
        pane.reloadIfShowingListing()
        if let first = created.first { pane.select(name: first) }
        registerCreatedUndo(names: created, in: folder, actionName: L("bvc.duplicateAction", "Duplicate"))
        if !failures.isEmpty { presentFailures(failures, title: L("bvc.duplicateFailed", "Couldn’t duplicate")) }
    }

    /// Set metadata (dates, permissions, tags) across the whole selection at once.
    func setAttributesSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        bulkAttributes.present(count: urls.count, over: window) { [weak self] changes in
            guard !changes.isEmpty else { return }
            Task { @MainActor in
                let result = await Task.detached { BulkAttributes.apply(changes, to: urls) }.value
                self?.activePane?.reloadIfShowingListing()
                if !result.failures.isEmpty {
                    self?.presentFailures(result.failures, title: L("bvc.setAttrsFailed", "Couldn’t set attributes"))
                }
            }
        }
    }

    /// Compare the two selected files side by side.
    func compareSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let entries = pane.selectedEntries
        guard entries.count == 2, entries.allSatisfy({ !$0.isDirectory }) else { NSSound.beep(); return }
        diffViewer.present(
            left: pane.currentURL.appendingPathComponent(entries[0].name),
            right: pane.currentURL.appendingPathComponent(entries[1].name), over: view.window)
    }

    /// Show the extended-attributes panel for the single selected item.
    func showXattrs() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let entry = pane.selectedEntries.first
        else { NSSound.beep(); return }
        xattrController.present(for: pane.currentURL.appendingPathComponent(entry.name), over: view.window)
    }

    /// Strip com.apple.quarantine from the selection (recursively for folders/bundles).
    func removeQuarantineFromSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let total = urls.reduce(0) { $0 + ExtendedAttributes.removeQuarantine(from: $1) }
        pane.reloadIfShowingListing()
        presentInfo(
            L("bvc.quarantineDone", "Quarantine"),
            total > 0
                ? String(format: L("bvc.quarantineRemoved", "Cleared the download flag from %d item(s)."), total)
                : L("bvc.quarantineNone", "No quarantine flags were set."))
    }

    /// Set (or clear) the Finder comment on every selected item, prefilled with the shared comment
    /// when they all match. Applied off-main through the engine writer.
    func setFinderCommentSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        let existing = Set(urls.map { FileMetadata.finderComment(of: $0) ?? "" })
        let prefill = existing.count == 1 ? (existing.first ?? "") : ""

        let alert = NSAlert()
        alert.messageText =
            urls.count == 1
            ? String(format: L("comment.titleOne", "Finder comment for “%@”"), urls[0].lastPathComponent)
            : String(format: L("comment.titleMany", "Finder comment for %d items"), urls.count)
        alert.informativeText = L("comment.hint", "Leave empty to remove the comment.")
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = prefill
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let comment = field.stringValue
            let failures = await Task.detached { () -> [FileOperations.Failure] in
                var failures: [FileOperations.Failure] = []
                for url in urls {
                    do { try FileMetadata.setFinderComment(comment, on: url) } catch {
                        failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
                    }
                }
                return failures
            }.value
            self.activePane?.reloadIfShowingListing()
            if !failures.isEmpty {
                self.presentFailures(failures, title: L("comment.failed", "Couldn’t set the comment"))
            }
        }
    }

    /// Open the bulk metadata editor over the selection (EXIF/IPTC for images, Finder tags/comment
    /// for anything), applying edits to every selected item at once.
    func editMetadataSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        metadataEditor.onApplied = { [weak self] count, failures in
            self?.activePane?.reloadIfShowingListing()
            if !failures.isEmpty {
                self?.presentFailures(failures, title: L("meta.applyFailed", "Some items couldn’t be updated"))
            } else if count > 0 {
                self?.activePane?.flashStatus(
                    String(format: L("meta.applied", "Updated metadata on %d item(s)"), count))
            }
        }
        metadataEditor.present(urls: urls, over: window)
    }

    /// Copy the selection's file names to the clipboard, one per line. Uses the entries' own
    /// names so it works everywhere — local, remote, and smart results.
    func copyNames() {
        let names = activePane?.selectedEntries.map(\.name) ?? []
        guard !names.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        flashCopied(count: names.count, kind: L("flash.name", "name"))
    }

    /// Confirm a copy-to-clipboard in the status line ("Copied 3 paths"), our toast channel.
    func flashCopied(count: Int, kind: String) {
        let message =
            count == 1
            ? String(format: L("flash.copiedOne", "Copied %@"), kind)
            : String(format: L("flash.copiedMany", "Copied %d %@s"), count, kind)
        activePane?.flashStatus(message)
    }
}
