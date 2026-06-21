import Foundation

/// A normalized keyboard chord (modifiers plus a key token), with a canonical
/// string form like "cmd+shift+z" or "f5" that is stable to serialize and
/// hand-edit. No AppKit dependency: the app builds one from an NSEvent's raw
/// fields via `from(...)`.
public struct KeyChord: Hashable, Sendable {
    public let key: String
    public let cmd: Bool
    public let opt: Bool
    public let ctrl: Bool
    public let shift: Bool

    public init(
        key: String, cmd: Bool = false, opt: Bool = false, ctrl: Bool = false, shift: Bool = false
    ) {
        self.key = key
        self.cmd = cmd
        self.opt = opt
        self.ctrl = ctrl
        self.shift = shift
    }

    /// Stable string form: modifiers in a fixed order, then the key token.
    public var canonical: String {
        var parts: [String] = []
        if cmd { parts.append("cmd") }
        if opt { parts.append("opt") }
        if ctrl { parts.append("ctrl") }
        if shift { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Build a chord from a key event's raw fields. Pass charactersIgnoringModifiers,
    /// which still applies Shift, so a letter key maps to its base letter (via
    /// lowercasing) and a shifted symbol is folded back to its unshifted key so
    /// that, for example, Shift plus "." canonicalizes to "shift+." not "shift+>".
    public static func from(
        keyCode: UInt16, characters: String?,
        cmd: Bool, opt: Bool, ctrl: Bool, shift: Bool
    ) -> KeyChord {
        var key = specialKeys[keyCode] ?? (characters?.lowercased() ?? "")
        if specialKeys[keyCode] == nil, shift, let base = shiftedSymbols[key] { key = base }
        return KeyChord(key: key, cmd: cmd, opt: opt, ctrl: ctrl, shift: shift)
    }

    /// US-layout shifted punctuation folded back to its base key. lowercased()
    /// folds letters but not symbols, so a shifted ">" must map to ".".
    private static let shiftedSymbols: [String: String] = [
        ">": ".", "<": ",", "?": "/", ":": ";", "\"": "'", "{": "[", "}": "]",
        "|": "\\", "+": "=", "_": "-", ")": "0", "(": "9", "*": "8", "&": "7",
        "^": "6", "%": "5", "$": "4", "#": "3", "@": "2", "!": "1", "~": "`",
    ]

    private static let specialKeys: [UInt16: String] = [
        36: "return", 76: "enter", 48: "tab", 53: "escape", 49: "space",
        51: "delete", 117: "forwarddelete",
        123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        33: "[", 30: "]",
    ]
}

/// Maps key chords (canonical strings) to command ids. Serializes as a flat,
/// hand-editable JSON object { "f5": "files.copyToOtherPane", ... }, stored in
/// Application Support and overlaid on the built-in defaults (config-as-data,
/// DESIGN.md section 10).
public struct Keymap: Codable, Sendable {
    public var bindings: [String: String]

    public init(bindings: [String: String]) { self.bindings = bindings }

    public func commandID(for chord: KeyChord) -> String? { bindings[chord.canonical] }

    public static let defaultBindings: [String: String] = [
        "return": "files.open",
        "enter": "files.open",
        "cmd+down": "files.open",
        "cmd+up": "nav.up",
        "cmd+[": "nav.back",
        "cmd+]": "nav.forward",
        "f5": "files.copyToOtherPane",
        "f6": "files.moveToOtherPane",
        "cmd+shift+.": "view.toggleHidden",
        "cmd+shift+p": "palette.show",
    ]

    public static var standard: Keymap { Keymap(bindings: defaultBindings) }

    /// Overlay user bindings on this keymap. An empty command id unbinds a chord.
    public func merging(userBindings: [String: String]) -> Keymap {
        var merged = bindings
        for (chord, command) in userBindings {
            if command.isEmpty { merged[chord] = nil } else { merged[chord] = command }
        }
        return Keymap(bindings: merged)
    }
}
