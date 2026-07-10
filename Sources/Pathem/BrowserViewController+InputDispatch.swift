import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Resolve a key chord against the keymap and dispatch via the registry.
    /// Returns true if a binding existed (so the key is consumed even when the
    /// command is currently disabled).
    func handleKeyChord(_ chord: KeyChord) -> Bool {
        if vimMode, handleVimKey(chord) { return true }  // vim keys take precedence when enabled
        // Don't consume a chord whose command is currently disabled, so the event
        // falls through (e.g. Cmd-W with one tab should reach Close Window).
        guard let id = keymap.commandID(for: chord), commands.command(id)?.isEnabled() == true else {
            return false
        }
        commands.perform(id)
        return true
    }

    /// Map a plain (unmodified) key to a navigation action in vim mode: h/j/k/l move, gg/G jump to
    /// the top/bottom, / focuses the filter. Returns true when it consumed the key.
    func handleVimKey(_ chord: KeyChord) -> Bool {
        guard !chord.cmd, !chord.ctrl, !chord.opt, !isEditingText else { vimPendingG = false; return false }
        let hadPendingG = vimPendingG
        vimPendingG = false
        switch (chord.key, chord.shift) {
        case ("j", false): activePane?.moveSelection(by: 1)
        case ("k", false): activePane?.moveSelection(by: -1)
        case ("h", false): if commands.command("nav.up")?.isEnabled() == true { commands.perform("nav.up") }
        case ("l", false), ("l", true): if commands.command("files.open")?.isEnabled() == true { commands.perform("files.open") }
        case ("g", false):
            if hadPendingG { activePane?.selectFirst() } else { vimPendingG = true }
        case ("g", true): activePane?.selectLast()  // Shift-G
        case ("/", _): if commands.command("view.filter")?.isEnabled() == true { commands.perform("view.filter") }
        default: return false
        }
        return true
    }

    func loadKeymap() {
        if let user = loadConfig([String: String].self, from: Self.keymapURL) {
            keymap = Keymap.standard.merging(userBindings: user)
        } else {
            keymap = .standard
        }
    }

    /// Resolve a mouse-gesture stroke against the gesture map and dispatch it.
    func handleGesture(_ stroke: String) -> Bool {
        guard let id = gestureMap.commandID(for: stroke), commands.command(id)?.isEnabled() == true
        else { return false }
        commands.perform(id)
        return true
    }

    /// Super-drag: draw the swipe trail as a row drag moves, and on a flick release (the drag
    /// ended past the threshold without a drop target) run its mapped command on the selection.
    /// Gated on the preference; when off, drags behave exactly as before.
    func handleDragSession(_ event: DragSessionEvent) {
        guard prefs.dragFlickActions else { return }
        switch event {
        case .began(let screen):
            dragStartScreen = screen
            dragTrail.color = NSColor(hex: prefs.dragTrailColor) ?? .systemBlue
            dragTrail.trailWidth = max(1, CGFloat(prefs.dragTrailWidth))
            dragTrail.decaySeconds = max(0.1, prefs.dragTrailDecay)
            dragTrail.hint = ""
            dragTrail.begin()
        case .moved(let screen):
            guard let window = view.window else { return }
            // Name the flick this direction would trigger (same threshold as the release),
            // so the trail shows what it's shortcutting; blank until it's a clear flick.
            if let start = dragStartScreen {
                let direction = MouseGesture.reduce([start, screen], minSegment: 44)
                dragTrail.hint = direction.isEmpty ? "" : flickHint(for: direction)
            }
            let windowPoint = window.convertPoint(fromScreen: screen)
            dragTrail.add(dragTrail.convert(windowPoint, from: nil))
        case .ended(let flick):
            dragStartScreen = nil
            dragTrail.end()
            guard let flick, let id = dragGestures.commandID(for: flick),
                commands.command(id)?.isEnabled() == true
            else { return }
            commands.perform(id)
        }
    }

    /// The command a flick `direction` maps to, as "Title  ⌘K" (its keyboard equivalent), for
    /// the trail's live hint. The shortcut is the simplest keymap chord bound to that command.
    func flickHint(for direction: String) -> String {
        guard let id = dragGestures.commandID(for: direction), let title = commands.command(id)?.title
        else { return "" }
        let chord = keymap.bindings.filter { $0.value == id }.keys.sorted().first
        let shortcut = chord.map { ChordFormat.display($0) } ?? ""
        return shortcut.isEmpty ? title : "\(title)   \(shortcut)"
    }

    func loadGestures() {
        if let user = loadConfig([String: String].self, from: Self.gesturesURL) {
            gestureMap = GestureMap.standard.merging(userBindings: user)
        } else {
            gestureMap = .standard
        }
    }
}
