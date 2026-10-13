import Foundation
import Testing

@testable import PathemEngine

@Suite struct OpenerRulesTests {
    @Test func precedenceFileOverFolderOverType() {
        var r = OpenerRules()
        r.setType("txt", app: "/Applications/TextEdit.app")
        r.setFolder("/fixture/home/Notes", app: "/Applications/Bear.app")
        r.setFile("/fixture/home/Notes/secret.txt", app: "/Applications/Vim.app")

        // File rule wins.
        #expect(
            r.app(forPath: "/fixture/home/Notes/secret.txt", ext: "txt") == "/Applications/Vim.app")
        // Folder rule (no file rule) beats the type rule.
        #expect(
            r.app(forPath: "/fixture/home/Notes/todo.txt", ext: "txt") == "/Applications/Bear.app")
        // Only the type rule applies elsewhere.
        #expect(
            r.app(forPath: "/fixture/home/Desktop/a.txt", ext: "txt")
                == "/Applications/TextEdit.app")
        // No rule at all.
        #expect(r.app(forPath: "/fixture/home/Desktop/a.png", ext: "png") == nil)
    }

    @Test func longestFolderRuleWins() {
        var r = OpenerRules()
        r.setFolder("/fixture/home", app: "/Applications/A.app")
        r.setFolder("/fixture/home/Code", app: "/Applications/B.app")
        #expect(
            r.app(forPath: "/fixture/home/Code/main.swift", ext: "swift") == "/Applications/B.app")
        #expect(r.app(forPath: "/fixture/home/notes.swift", ext: "swift") == "/Applications/A.app")
    }

    @Test func typeKeyIsCaseInsensitive() {
        var r = OpenerRules()
        r.setType("PNG", app: "/Applications/Preview.app")
        #expect(r.app(forPath: "/a/b.png", ext: "png") == "/Applications/Preview.app")
        #expect(r.app(forPath: "/a/b.PNG", ext: "PNG") == "/Applications/Preview.app")
    }

    @Test func fileOrFolderResolverExcludesType() {
        var r = OpenerRules()
        r.setType("txt", app: "/Applications/TextEdit.app")
        r.setFolder("/fixture/home/Notes", app: "/Applications/Bear.app")
        // file/folder-only: type rule must NOT apply (so session-by-type can layer between).
        #expect(r.appByFileOrFolder(path: "/fixture/home/Notes/a.txt") == "/Applications/Bear.app")
        #expect(r.appByFileOrFolder(path: "/fixture/home/Desktop/a.txt") == nil)
        #expect(r.app(forType: "txt") == "/Applications/TextEdit.app")
    }

    @Test func codableRoundTrip() throws {
        var r = OpenerRules()
        r.setFile("/a/b.txt", app: "/Applications/Vim.app")
        r.setType("md", app: "/Applications/Bear.app")
        let back = try JSONDecoder().decode(OpenerRules.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }

    @Test func extensionlessNamesGetTheirOwnKindKey() {
        #expect(OpenerRules.kindKey(forFileName: ".env") == "name:.env")
        #expect(OpenerRules.kindKey(forFileName: "Makefile") == "name:makefile")
        #expect(OpenerRules.kindKey(forFileName: "notes.TXT") == "txt")
        #expect(OpenerRules.kindKey(forFileName: ".env.local") == "local")
        // Two different extension-less files must never share a key.
        #expect(
            OpenerRules.kindKey(forFileName: ".env")
                != OpenerRules.kindKey(forFileName: "Makefile"))
    }

    @Test func nameRuleMatchesOnlyThatName() {
        var r = OpenerRules()
        r.setName(".ENV", app: "/Applications/Code.app")
        #expect(r.app(forName: ".env") == "/Applications/Code.app")
        #expect(r.app(forName: "Makefile") == nil)
        #expect(r.app(forName: ".gitignore") == nil)
    }

    @Test func olderFileWithoutNameMapStillLoadsItsRules() throws {
        let json = #"{"byFile":{"/a/b.txt":"/Applications/X.app"},"byFolder":{},"byType":{}}"#
        let r = try JSONDecoder().decode(OpenerRules.self, from: Data(json.utf8))
        #expect(r.byFile["/a/b.txt"] == "/Applications/X.app")
        #expect(r.byName.isEmpty)
        var withName = r
        withName.setName(".env", app: "/Applications/Code.app")
        let round = try JSONDecoder().decode(
            OpenerRules.self, from: JSONEncoder().encode(withName))
        #expect(round == withName)
    }
}
