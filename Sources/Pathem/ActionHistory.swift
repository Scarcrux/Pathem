import AppKit

/// The app's authoritative undo/redo history for file operations (replacing NSUndoManager), so
/// we can show a recent-actions panel and, later, selectively undo an action that no newer
/// action depends on. Each entry records the paths it touched (its footprint) and the paths its
/// undo would touch, plus a closure that performs the reverse -- which re-records the opposite
/// via `record`, exactly as NSUndoManager's register-during-undo works, so redo just works.
@MainActor
final class ActionHistory {
    struct Action: Identifiable {
        let id = UUID()
        let name: String
        let date: Date
        let footprint: Set<String>  // paths this action created / changed
        let undoFootprint: Set<String>  // paths undoing it would touch
        let perform: () -> Void  // reverse the action (and record the opposite)
    }

    private(set) var undoStack: [Action] = []
    private(set) var redoStack: [Action] = []
    /// Fired after any change, so the menu and panel refresh.
    var onChange: (() -> Void)?

    private enum Phase { case idle, undoing, redoing }
    private var phase: Phase = .idle

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String? { undoStack.last?.name }
    var redoActionName: String? { redoStack.last?.name }

    /// Record an action. During an undo the recording goes to the redo stack (and vice versa),
    /// mirroring NSUndoManager, so the existing "the undo closure re-registers the opposite"
    /// pattern keeps working unchanged.
    func record(
        name: String, footprint: Set<String>, undoFootprint: Set<String>,
        perform: @escaping () -> Void
    ) {
        let action = Action(
            name: name, date: Date(), footprint: footprint, undoFootprint: undoFootprint,
            perform: perform)
        switch phase {
        case .idle:
            undoStack.append(action)
            redoStack.removeAll()  // a fresh action invalidates the redo chain
        case .undoing:
            redoStack.append(action)
        case .redoing:
            undoStack.append(action)
        }
        onChange?()
    }

    func undo() { run(&undoStack, phase: .undoing) }
    func redo() { run(&redoStack, phase: .redoing) }

    private func run(_ stack: inout [Action], phase newPhase: Phase) {
        guard let action = stack.popLast() else { return }
        phase = newPhase
        action.perform()  // reverses, and records the opposite onto the other stack
        phase = .idle
        onChange?()
    }

    /// Whether the undo-stack action at `index` can be undone on its own right now: no *newer*
    /// action's footprint overlaps the paths its undo would touch (nor vice versa). If one does,
    /// that newer action depends on it and must be undone first. The basis for selective undo.
    func isIndependentlyUndoable(at index: Int) -> Bool {
        guard undoStack.indices.contains(index) else { return false }
        let target = undoStack[index]
        for newer in undoStack[(index + 1)...] {
            if !newer.footprint.isDisjoint(with: target.undoFootprint) { return false }
            if !newer.undoFootprint.isDisjoint(with: target.footprint) { return false }
        }
        return true
    }
}
