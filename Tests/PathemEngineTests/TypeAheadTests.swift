import Foundation
import Testing

@testable import PathemEngine

@Suite struct TypeAheadTests {
    // MARK: mode parsing

    @Test func plainTextStaysInTheManualMode() {
        #expect(TypeAhead.parse("rep", manual: .find) == .init(mode: .find, query: "rep"))
        #expect(TypeAhead.parse("rep", manual: .filter) == .init(mode: .filter, query: "rep"))
    }

    @Test func pathPrefixesSwitchToGo() {
        for text in ["/usr", "~", "~/Doc", "..", "../x"] {
            #expect(TypeAhead.parse(text, manual: .find).mode == .go, "\(text)")
            #expect(TypeAhead.parse(text, manual: .filter).query == text)
        }
        // A dotfile or a name that merely starts with dots is not a path.
        #expect(TypeAhead.parse(".git", manual: .find).mode == .find)
        #expect(TypeAhead.parse("...", manual: .find).mode == .find)
    }

    @Test func commandAndSemanticPrefixesDropTheirMarker() {
        #expect(
            TypeAhead.parse(">new fol", manual: .find) == .init(mode: .command, query: "new fol"))
        #expect(
            TypeAhead.parse("?sunset photos", manual: .filter)
                == .init(mode: .semantic, query: "sunset photos"))
    }

    @Test func tabCyclesFindAndFilterOnly() {
        #expect(TypeAhead.cycled(.find) == .filter)
        #expect(TypeAhead.cycled(.filter) == .find)
        #expect(TypeAhead.cycled(.go) == .go)
    }

    // MARK: key eligibility

    @Test func onlyPlainPrintableKeysOpenTheField() {
        #expect(TypeAhead.opens(with: "a", cmd: false, opt: false, ctrl: false))
        #expect(TypeAhead.opens(with: "A", cmd: false, opt: false, ctrl: false))
        #expect(TypeAhead.opens(with: ">", cmd: false, opt: false, ctrl: false))
        #expect(!TypeAhead.opens(with: "a", cmd: true, opt: false, ctrl: false))
        #expect(!TypeAhead.opens(with: "a", cmd: false, opt: true, ctrl: false))
        #expect(!TypeAhead.opens(with: "a", cmd: false, opt: false, ctrl: true))
        #expect(!TypeAhead.opens(with: "\r", cmd: false, opt: false, ctrl: false))
        #expect(!TypeAhead.opens(with: "\u{1b}", cmd: false, opt: false, ctrl: false))
        #expect(!TypeAhead.opens(with: "\u{F700}", cmd: false, opt: false, ctrl: false))  // arrow
        #expect(!TypeAhead.opens(with: " ", cmd: false, opt: false, ctrl: false))
        #expect(!TypeAhead.opens(with: "", cmd: false, opt: false, ctrl: false))
        #expect(!TypeAhead.opens(with: "ab", cmd: false, opt: false, ctrl: false))
    }

    @Test func aBoundPlainKeyNeverOpensTheField() {
        let keymap = Keymap(bindings: ["j": "nav.down", "a": ""])
        #expect(!TypeAhead.shouldOpen(typed: "j", shift: false, keymap: keymap))
        #expect(TypeAhead.shouldOpen(typed: "k", shift: false, keymap: keymap))
        // The bound chord is "shift+j" for a capital J, so plain "j" binding does not block "J".
        let shifted = Keymap(bindings: ["shift+j": "x.y"])
        #expect(!TypeAhead.shouldOpen(typed: "J", shift: true, keymap: shifted))
        // Every default plain-key binding is respected, including a disabled command's.
        for chord in Keymap.defaultBindings.keys where !chord.contains("+") && chord.count == 1 {
            #expect(!TypeAhead.shouldOpen(typed: chord, shift: false, keymap: .standard))
        }
    }

    // MARK: find

    @Test func findRanksPrefixThenSubstringKeepingOrder() {
        let names = ["notes.txt", "Report.pdf", "annual report.pdf", "readme.md", "Reports", "x"]
        #expect(TypeAhead.matches(names: names, query: "rep") == [1, 4, 2])
        #expect(TypeAhead.matches(names: names, query: "REP") == [1, 4, 2])
        #expect(TypeAhead.matches(names: names, query: "zzz").isEmpty)
        #expect(TypeAhead.matches(names: names, query: "").isEmpty)
    }

    @Test func findIsDiacriticInsensitive() {
        #expect(TypeAhead.matches(names: ["Résumé.pdf", "other"], query: "resume") == [0])
    }

    @Test func stepWrapsAroundTheMatches() {
        #expect(TypeAhead.step(from: 0, count: 3, forward: true) == 1)
        #expect(TypeAhead.step(from: 2, count: 3, forward: true) == 0)
        #expect(TypeAhead.step(from: 0, count: 3, forward: false) == 2)
        #expect(TypeAhead.step(from: 0, count: 0, forward: true) == nil)
    }

    // MARK: go completion (real directories)

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeahead-\(UUID().uuidString)")
        for dir in ["Documents", "Downloads", "Desktop", "Music", ".hidden", "Docs Old"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("Doc.txt"))
        return root
    }

    @Test func goCompletesAUniqueFolderWithTrailingSlash() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = TypeAhead.completeGo(root.path + "/Mu", base: root)
        #expect(result.candidates == ["Music"])
        #expect(result.completed == root.path + "/Music/")
    }

    @Test func goExtendsToTheCommonPrefixWhenAmbiguous() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = TypeAhead.completeGo(root.path + "/D", base: root)
        #expect(Set(result.candidates) == ["Documents", "Downloads", "Desktop", "Docs Old"])
        #expect(result.completed == nil)  // "D" is already the common prefix
        let narrower = TypeAhead.completeGo(root.path + "/Do", base: root)
        #expect(Set(narrower.candidates) == ["Documents", "Downloads", "Docs Old"])
        #expect(narrower.completed == nil)  // "Do" is already the common prefix
        let more = TypeAhead.completeGo(root.path + "/Docu", base: root)
        #expect(more.completed == root.path + "/Documents/")
    }

    @Test func goListsOnlyFoldersAndHidesDotFoldersUnlessAsked() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!TypeAhead.completeGo(root.path + "/", base: root).candidates.contains("Doc.txt"))
        #expect(!TypeAhead.completeGo(root.path + "/", base: root).candidates.contains(".hidden"))
        #expect(TypeAhead.completeGo(root.path + "/.h", base: root).candidates == [".hidden"])
    }

    @Test func goResolvesRelativeParentAndTilde() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Music")
        #expect(TypeAhead.completeGo("../Mus", base: child).candidates == ["Music"])
        #expect(TypeAhead.completeGo("~/", base: child).candidates.isEmpty == false)
    }

    @Test func goTargetResolvesFoldersFilesAndMisses() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            TypeAhead.goTarget(root.path + "/Music", base: root)
                == .folder(root.appendingPathComponent("Music").standardizedFileURL))
        #expect(
            TypeAhead.goTarget("Doc.txt", base: root)
                == .file(root.appendingPathComponent("Doc.txt").standardizedFileURL))
        #expect(
            TypeAhead.goTarget("..", base: root.appendingPathComponent("Music"))
                == .folder(root.standardizedFileURL))
        if case .missing = TypeAhead.goTarget(root.path + "/Nope", base: root) {
        } else {
            Issue.record("expected .missing")
        }
    }

    // MARK: command ranking

    @Test func commandsRankByTitleThenKeywords() {
        let items = [
            TypeAhead.CommandItem(id: "a", title: "New Folder", keywords: ["mkdir"]),
            TypeAhead.CommandItem(id: "b", title: "Settings…", keywords: ["Preferences"]),
            TypeAhead.CommandItem(id: "c", title: "Rename", keywords: []),
        ]
        #expect(TypeAhead.rankCommands(items, query: "pref").map(\.id) == ["b"])
        #expect(TypeAhead.rankCommands(items, query: "mkd").map(\.id) == ["a"])
        #expect(TypeAhead.rankCommands(items, query: "").isEmpty == false)
    }

    // MARK: preference

    @Test func findAsYouTypeDefaultsOnAndOldConfigsDecodeUnchanged() throws {
        let old = try JSONDecoder().decode(
            Preferences.self, from: Data(#"{"themeName":"System"}"#.utf8))
        #expect(old.findAsYouType == true)
        var prefs = Preferences()
        prefs.findAsYouType = false
        let round = try JSONDecoder().decode(
            Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(round.findAsYouType == false)
    }
}
