import AppKit
import PathemEngine

extension BrowserViewController {
    func configureActivityDrawer() {
        activityDrawer.canUndo = { [weak self] token in
            guard let self, let index = self.activityUndoIndex(token) else { return false }
            return !self.fileOperationBusy && self.actionHistory.isIndependentlyUndoable(at: index)
        }
        activityDrawer.onUndo = { [weak self] token in
            guard let self, !self.fileOperationBusy, let index = self.activityUndoIndex(token)
            else { return }
            self.actionHistory.undo(at: index)
            self.activityDrawer.refreshUndoState()
        }
        activityDrawer.onReveal = { record in
            let paths = [record.destination].compactMap { $0 } + record.sources
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) })
            else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func toggleActivityDrawer() {
        activityDrawer.view.isHidden.toggle()
        if !activityDrawer.view.isHidden { activityDrawer.reload() }
    }

    private func activityUndoIndex(_ token: String) -> Int? {
        guard let id = UUID(uuidString: token) else { return nil }
        return actionHistory.undoStack.firstIndex { $0.id == id }
    }

    static func recordActivity(
        _ operation: String, sources: [URL], destination: URL? = nil,
        completed: Int, failures: [FileOperations.Failure] = [],
        skipped: Int = 0, bytes: Int64? = nil, canceled: Bool = false, undo: UUID? = nil
    ) {
        let outcome: OperationRecord.Outcome
        if canceled {
            outcome = completed > 0 ? .partial : .canceled
        } else if !failures.isEmpty || skipped > 0 {
            outcome = completed > 0 ? .partial : .failed
        } else {
            outcome = completed > 0 ? .ok : .canceled
        }
        OperationLogger.shared.record(
            OperationRecord(
                operation: operation, sources: sources.map(\.path),
                destination: destination?.path, bytes: bytes, outcome: outcome,
                error: failures.first?.reason, undoToken: undo?.uuidString))
    }
}
