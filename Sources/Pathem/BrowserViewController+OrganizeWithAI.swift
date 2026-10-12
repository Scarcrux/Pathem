import AppKit
import PathemEngine

// "Organize this folder with AI": the model proposes a typed OrganizePlan, the user confirms
// it, and our own code (not the model) executes the moves through the normal file-op + undo
// path. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    // MARK: - Organize with AI (typed plan; the model proposes, our code executes)

    func organizeWithAI() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        // Check the model up front (before prompting) so we explain instead of failing.
        if let reason = AIAvailability.unavailableReason() {
            AIAvailability.presentUnavailable(
                L("ai.organize.unavail", "Organize with AI is unavailable"), reason: reason,
                over: view.window)
            return
        }
        let folder = pane.currentURL
        let files =
            pane.selectedEntries.isEmpty
            ? pane.entries.map(\.name) : pane.selectedEntries.map(\.name)
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            guard
                let instruction = await self.promptForName(
                    title: L("ai.organize.title", "Organize with AI"), default: "group by file type"
                )
            else { return }

            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                guard let plan = await proposeOrganizePlan(instruction: instruction, files: files),
                    !plan.steps.isEmpty
                else {
                    self.presentInfo(
                        L("ai.organize.noPlan.title", "Couldn’t propose a plan"),
                        L("ai.organize.noPlan.body", "The model returned no steps."))
                    return
                }
                self.confirmAndRun(plan, in: folder)
            }
            #endif
        }
    }

    /// Preview the plan, then execute it on confirmation (off-main) and report.
    private func confirmAndRun(_ plan: OrganizePlan, in folder: URL) {
        let lines = plan.summary(in: folder)
        let alert = NSAlert()
        alert.messageText = String(
            format: L("bvc.organizeQ", "Organize %@?"), folder.lastPathComponent)
        alert.informativeText =
            lines.prefix(20).joined(separator: "\n") + (lines.count > 20 ? "\n…" : "")
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let result = await Task.detached { plan.execute(in: folder) }.value
                self.reloadBothSides()
                // Register undo like every other local file op (moves + trashes).
                if !result.performed.isEmpty {
                    self.registerUndo(
                        result.performed, actionName: L("bvc.organizeAction", "Organize"))
                }
                if !result.trashedItems.isEmpty { self.registerTrashUndo(result.trashedItems) }
                self.presentInfo(
                    L("bvc.organized", "Organized"),
                    String(
                        format: L("bvc.organizedSummary", "Moved %d, trashed %d, labeled %d"),
                        result.moved, result.trashed, result.labeled)
                        + (result.failures.isEmpty
                            ? ""
                            : String(
                                format: L("bvc.organizedSkippedSuffix", ", %d skipped"),
                                result.failures.count)))
            }
        }
    }

    // MARK: - Organize Folder (deterministic rules; no model required)

    static var organizeFeedbackURL: URL? {
        appSupportDirectory()?.appendingPathComponent("organize-feedback.json")
    }

    /// Propose a rules-based organization for the active pane's folder and present the
    /// review sheet: every suggestion is a row the user can inspect, skip, or rate, and
    /// only the checked ones are applied (undoable, like every other local file op).
    func organizeFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        guard let window = view.window else { return }
        let folder = pane.currentURL
        let destinations = FilingDestinations.defaults(
            home: FileManager.default.homeDirectoryForCurrentUser)
        let memory =
            Self.organizeFeedbackURL.map { OrganizeFeedback.load(from: $0) } ?? OrganizeFeedback()
        Task { @MainActor [self] in
            let suggestions = await Task.detached {
                OrganizePlanner.suggestions(for: folder, destinations: destinations, memory: memory)
            }.value
            guard !suggestions.isEmpty else {
                self.presentInfo(
                    L("organize.none.title", "Nothing to organize"),
                    L(
                        "organize.none.body",
                        "No suggestions for this folder (files you touched in the last day, and anything inside a git repo, are left alone)."
                    ))
                return
            }
            let review = OrganizeReviewController(
                feedbackURL: Self.organizeFeedbackURL
                    ?? folder.appendingPathComponent(".pathem-feedback.json"))
            self.organizeReview = review  // retain while the sheet is up
            review.present(
                suggestions: suggestions, folderName: folder.lastPathComponent,
                destinations: destinations,
                over: window
            ) { [weak self] finalized in
                self?.organizeReview = nil
                self?.runOrganize(finalized)
            }
        }
    }

    /// Apply the accepted suggestions (apply filters to the checked ones), reload, and
    /// register undo, then report what happened.
    private func runOrganize(_ suggestions: [OrganizePlanner.Suggestion]) {
        // Record the user's accept/skip decision as behavioral signal (this is what the
        // planner learns from next time), whether or not anything is applied.
        if let url = Self.organizeFeedbackURL {
            OrganizeFeedback.record(
                suggestions.map {
                    .init(
                        ruleID: $0.ruleID, destination: $0.destination?.lastPathComponent,
                        ext: $0.file.pathExtension.lowercased(),
                        verdict: $0.accepted ? .applied : .skipped)
                }, to: url)
        }
        guard suggestions.contains(where: \.accepted) else { return }  // user unchecked everything
        Task { @MainActor in
            let outcome = await Task.detached { OrganizePlanner.apply(suggestions) }.value
            self.reloadBothSides()
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: L("organize.action", "Organize"))
            }
            if !outcome.trashedItems.isEmpty { self.registerTrashUndo(outcome.trashedItems) }
            self.presentInfo(
                L("organize.done.title", "Organized"),
                String(
                    format: L("organize.done.body", "Moved %d, trashed %d"), outcome.moved,
                    outcome.trashed)
                    + (outcome.failures.isEmpty
                        ? ""
                        : String(
                            format: L("organize.done.skipped", ", %d skipped"),
                            outcome.failures.count)))
        }
    }
}
