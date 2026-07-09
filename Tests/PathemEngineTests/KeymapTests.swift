import Foundation
import Testing

@testable import PathemEngine

@Suite struct KeymapTests {
    @Test func canonicalOrdersModifiers() {
        #expect(KeyChord(key: "z", cmd: true, shift: true).canonical == "cmd+shift+z")
        #expect(KeyChord(key: "f5").canonical == "f5")
        #expect(KeyChord(key: "up", cmd: true).canonical == "cmd+up")
    }

    @Test func fromMapsSpecialKeysAndLetters() {
        #expect(
            KeyChord.from(keyCode: 96, characters: nil, cmd: false, opt: false, ctrl: false, shift: false)
                .canonical == "f5")
        #expect(
            KeyChord.from(keyCode: 36, characters: "\r", cmd: false, opt: false, ctrl: false, shift: false)
                .canonical == "return")
        // A letter keeps Shift as a modifier so cmd+z and cmd+shift+z differ.
        // AppKit delivers the uppercased letter for charactersIgnoringModifiers
        // when Shift is held, so feed "Z" (what really arrives), not "z".
        #expect(
            KeyChord.from(keyCode: 6, characters: "Z", cmd: true, opt: false, ctrl: false, shift: true)
                .canonical == "cmd+shift+z")
    }

    @Test func foldsShiftedPunctuationToBaseKey() {
        // Shift plus "." yields ">" from charactersIgnoringModifiers; it must
        // canonicalize to "cmd+shift+." so the default Show Hidden binding fires.
        #expect(
            KeyChord.from(keyCode: 47, characters: ">", cmd: true, opt: false, ctrl: false, shift: true)
                .canonical == "cmd+shift+.")
        #expect(
            Keymap.standard.commandID(for: KeyChord(key: ".", cmd: true, shift: true)) == "view.toggleHidden")
    }

    @Test func defaultKeymapLookups() {
        let keymap = Keymap.standard
        #expect(keymap.commandID(for: KeyChord(key: "f5")) == "files.copyToOtherPane")
        #expect(keymap.commandID(for: KeyChord(key: "up", cmd: true)) == "nav.up")
        #expect(keymap.commandID(for: KeyChord(key: "x")) == nil)  // plain letter is unbound
        // Common hotkeys: plain Delete trashes, F2 renames, Cmd+L / Cmd+Shift+G go to a path.
        #expect(keymap.commandID(for: KeyChord(key: "delete")) == "files.trash")
        #expect(keymap.commandID(for: KeyChord(key: "f2")) == "files.rename")
        #expect(keymap.commandID(for: KeyChord(key: "l", cmd: true)) == "nav.editPath")
        #expect(keymap.commandID(for: KeyChord(key: "g", cmd: true, shift: true)) == "nav.editPath")
        // Home / End jump the selection to the first / last item.
        #expect(keymap.commandID(for: KeyChord(key: "home")) == "nav.selectFirst")
        #expect(keymap.commandID(for: KeyChord(key: "end")) == "nav.selectLast")
    }

    @Test func homeEndKeyCodesResolveToJumps() {
        // Home = keyCode 115, End = 119, no modifiers -> the selection-jump commands.
        let home = KeyChord.from(keyCode: 115, characters: nil, cmd: false, opt: false, ctrl: false, shift: false)
        let end = KeyChord.from(keyCode: 119, characters: nil, cmd: false, opt: false, ctrl: false, shift: false)
        #expect(home.canonical == "home")
        #expect(end.canonical == "end")
        #expect(Keymap.standard.commandID(for: home) == "nav.selectFirst")
        #expect(Keymap.standard.commandID(for: end) == "nav.selectLast")
    }

    @Test func userBindingsOverrideAndUnbind() {
        let keymap = Keymap.standard.merging(userBindings: [
            "f5": "files.moveToOtherPane",  // rebind
            "f6": "",  // unbind
        ])
        #expect(keymap.commandID(for: KeyChord(key: "f5")) == "files.moveToOtherPane")
        #expect(keymap.commandID(for: KeyChord(key: "f6")) == nil)
    }

    @Test func codableRoundTrip() throws {
        let keymap = Keymap(bindings: ["f5": "a", "cmd+z": "b"])
        let data = try JSONEncoder().encode(keymap)
        let restored = try JSONDecoder().decode(Keymap.self, from: data)
        #expect(restored.bindings == keymap.bindings)
    }
}
