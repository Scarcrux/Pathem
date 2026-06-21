import Foundation
import Testing

@testable import PathomEngine

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
        #expect(
            KeyChord.from(keyCode: 6, characters: "z", cmd: true, opt: false, ctrl: false, shift: true)
                .canonical == "cmd+shift+z")
    }

    @Test func defaultKeymapLookups() {
        let keymap = Keymap.standard
        #expect(keymap.commandID(for: KeyChord(key: "f5")) == "files.copyToOtherPane")
        #expect(keymap.commandID(for: KeyChord(key: "up", cmd: true)) == "nav.up")
        #expect(keymap.commandID(for: KeyChord(key: "x")) == nil)  // plain letter is unbound
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
