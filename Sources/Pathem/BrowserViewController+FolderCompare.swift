import AppKit
import PathemEngine

// Compare-panes and its Sync/Mirror follow-through: diff the two panes' folders, offer a
// two-way sync (newer wins, never deletes) or a one-way mirror (preview-then-apply, with
// an explicit confirmation before any deletions), split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Compare the two panes' folders and offer a one-way mirror (preview-then-apply).
    func comparePanes() {
        guard let left = leftTabs.activePane, let right = rightTabs.activePane,
            !left.isRemote, !right.isRemote
        else { NSSound.beep(); return }
        let leftURL = left.currentURL
        let rightURL = right.currentURL
        guard leftURL != rightURL else { NSSound.beep(); return }
        Task { @MainActor [weak self] in
            let diffs = await Task.detached { FolderCompare.compare(left: leftURL, right: rightURL) }.value
            self?.presentCompare(diffs, leftURL: leftURL, rightURL: rightURL)
        }
    }

    func presentCompare(_ diffs: [FolderCompare.Difference], leftURL: URL, rightURL: URL) {
        let s = FolderCompare.summary(diffs)
        let alert = NSAlert()
        alert.messageText = String(
            format: L("bvc.compareTitle", "Compare: %@ ↔ %@"),
            leftURL.lastPathComponent, rightURL.lastPathComponent)
        alert.informativeText = String(
            format: L("bvc.compareSummary", "Only on left: %d\nOnly on right: %d\nDiffer: %d\nIdentical: %d"),
            s.onlyLeft, s.onlyRight, s.differs, s.identical)
        let deleteExtras = NSButton(checkboxWithTitle: L("bvc.alsoDeleteMissing", "Also delete files missing from the source (mirror only)"), target: nil, action: nil)
        alert.accessoryView = deleteExtras
        alert.addButton(withTitle: L("bvc.syncTwoWay", "Sync Both Ways (newer wins)"))
        alert.addButton(withTitle: L("bvc.mirrorLeftToRight", "Mirror Left → Right"))
        alert.addButton(withTitle: L("bvc.mirrorRightToLeft", "Mirror Right → Left"))
        alert.addButton(withTitle: L("common.close", "Close"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let delete = deleteExtras.state == .on
            switch response {
            case .alertFirstButtonReturn: self?.runSync(left: leftURL, right: rightURL)
            case .alertSecondButtonReturn: self?.runMirror(source: leftURL, target: rightURL, deleteExtras: delete)
            case .alertThirdButtonReturn: self?.runMirror(source: rightURL, target: leftURL, deleteExtras: delete)
            default: break
            }
        }
    }

    /// Two-way additive sync (recompute fresh, apply off-main): copy each side's unique
    /// and newer files to the other; never deletes.
    func runSync(left: URL, right: URL) {
        Task { @MainActor [weak self] in
            let actions = await Task.detached {
                FolderSync.plan(left: left, right: right, conflict: .newerWins)
            }.value
            guard let self else { return }
            let toRight = actions.filter { $0.direction == .toRight }
            let toLeft = actions.filter { $0.direction == .toLeft }
            let conflicts = actions.filter { $0.direction == nil && $0.wasConflict }
            if toRight.isEmpty && toLeft.isEmpty {
                self.presentInfo(
                    L("sync.upToDateTitle", "Already in sync"),
                    conflicts.isEmpty
                        ? L("sync.upToDateBody", "Both folders already match.")
                        : String(
                            format: L("sync.upToDateConflicts", "Both folders match except %d file(s) that changed on both sides at the same time; those are left untouched."),
                            conflicts.count))
                return
            }
            // Two-way sync copies files across; show exactly what will move before doing it.
            guard await self.confirmSync(toRight: toRight, toLeft: toLeft, conflicts: conflicts, left: left, right: right)
            else { return }
            let result = await Task.detached { FolderSync.execute(actions, left: left, right: right) }.value
            self.reloadBothSides()
            self.presentSyncResult(result)
        }
    }

    /// Preview what a two-way sync will copy in each direction (with a sample of file names)
    /// and how many conflicts it will leave alone, and return whether the user confirmed.
    func confirmSync(
        toRight: [FolderSync.Action], toLeft: [FolderSync.Action], conflicts: [FolderSync.Action],
        left: URL, right: URL
    ) async -> Bool {
        guard let window = view.window else { return false }
        func sample(_ actions: [FolderSync.Action], _ arrow: String) -> String {
            var lines = actions.prefix(6).map { "  \(arrow) \($0.relativePath)" }
            if actions.count > 6 {
                lines.append("  " + String(format: L("sync.more", "…and %d more"), actions.count - 6))
            }
            return lines.joined(separator: "\n")
        }
        var body = ""
        if !toRight.isEmpty {
            body += String(format: L("sync.toRightHeader", "Copy %d into %@:"), toRight.count, right.lastPathComponent)
            body += "\n" + sample(toRight, "→") + "\n\n"
        }
        if !toLeft.isEmpty {
            body += String(format: L("sync.toLeftHeader", "Copy %d into %@:"), toLeft.count, left.lastPathComponent)
            body += "\n" + sample(toLeft, "←") + "\n\n"
        }
        if !conflicts.isEmpty {
            body += String(
                format: L("sync.conflictsNote", "%d file(s) changed on both sides at the same time; those are left untouched.\n\n"),
                conflicts.count)
        }
        body += L("sync.nothingDeleted", "Nothing is deleted. Only newer and missing files are copied.")

        let alert = NSAlert()
        alert.messageText = String(
            format: L("sync.confirmTitle", "Sync %@ ↔ %@"), left.lastPathComponent, right.lastPathComponent)
        alert.informativeText = body
        alert.addButton(withTitle: L("sync.confirmGo", "Sync"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    func presentSyncResult(_ result: FolderSync.Result) {
        let alert = NSAlert()
        alert.messageText = L("bvc.syncComplete", "Sync complete")
        var info = String(
            format: L("bvc.syncCopied", "Copied %d to the right, %d to the left"),
            result.copiedToRight, result.copiedToLeft)
        if result.conflictsSkipped > 0 {
            info += String(
                format: L("bvc.syncConflicts", "\n%d conflicts skipped (same time on both sides)"),
                result.conflictsSkipped)
        }
        if !result.failures.isEmpty {
            info += String(format: L("bvc.mirrorFailedSuffix", ", %d failed"), result.failures.count)
        }
        alert.informativeText = info
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
    }

    /// Mirror `source` onto `target`. Recompute the diff fresh, and when the mirror would
    /// DELETE files from the target (deleteExtras), show exactly which ones and require
    /// explicit confirmation before touching anything. Then apply off-main.
    func runMirror(source: URL, target: URL, deleteExtras: Bool) {
        Task { @MainActor [weak self] in
            let diffs = await Task.detached { FolderCompare.compare(left: source, right: target) }.value
            guard let self else { return }
            let plan = FolderCompare.mirrorPlan(diffs, deleteExtras: deleteExtras)
            if plan.copies.isEmpty && plan.deletes.isEmpty {
                self.presentInfo(
                    L("bvc.mirrorNothing", "Already mirrored"),
                    String(format: L("bvc.mirrorNothingBody", "%@ already matches the source."), target.lastPathComponent))
                return
            }
            // Deletions are destructive: preview them and require a second confirmation.
            if !plan.deletes.isEmpty {
                guard await self.confirmMirrorDeletions(plan, target: target) else { return }
            }
            let result = await Task.detached {
                FolderCompare.mirror(from: source, to: target, differences: diffs, deleteExtras: deleteExtras)
            }.value
            self.reloadBothSides()
            let alert = NSAlert()
            alert.messageText = L("bvc.mirrorComplete", "Mirror complete")
            alert.informativeText =
                String(format: L("bvc.mirrorCopiedDeleted", "Copied %d, deleted %d"), result.copied, result.deleted)
                + (result.failures.isEmpty ? "" : String(format: L("bvc.mirrorFailedSuffix", ", %d failed"), result.failures.count))
            alert.addButton(withTitle: L("common.ok", "OK"))
            if let window = self.view.window { alert.beginSheetModal(for: window) { _ in } }
        }
    }

    /// Show the itemized deletions a mirror will perform (the files trashed on the target),
    /// plus the copy count, and return whether the user confirmed.
    func confirmMirrorDeletions(
        _ plan: (copies: [String], deletes: [String]), target: URL
    ) async -> Bool {
        guard let window = view.window else { return false }
        let shown = plan.deletes.prefix(12).map { "• \($0)" }.joined(separator: "\n")
        let more =
            plan.deletes.count > 12
            ? "\n" + String(format: L("bvc.mirrorMore", "…and %d more."), plan.deletes.count - 12) : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: L("bvc.mirrorConfirmTitle", "Mirror will delete %d item(s) from %@"),
            plan.deletes.count, target.lastPathComponent)
        alert.informativeText =
            String(
                format: L("bvc.mirrorConfirmBody", "These files exist in %@ but not in the source, so mirroring moves them to the Trash. %d file(s) will also be copied.\n\n%@%@"),
                target.lastPathComponent, plan.copies.count, shown, more)
        alert.addButton(withTitle: L("bvc.mirrorConfirmGo", "Mirror and Delete"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
