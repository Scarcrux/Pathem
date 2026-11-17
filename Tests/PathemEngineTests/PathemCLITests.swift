import Foundation
import Testing

@testable import PathemEngine

@Suite struct PathemCLITests {
    @Test func existingVerbsParse() {
        #expect(PathemCLI.parse(["open", "/a"]) == .act(verb: .open, path: "/a", printOnly: false))
        #expect(
            PathemCLI.parse(["reveal", "x y"]) == .act(verb: .reveal, path: "x y", printOnly: false)
        )
        #expect(
            PathemCLI.parse(["preview", "f", "--print"])
                == .act(verb: .preview, path: "f", printOnly: true))
    }

    @Test func bareAndChangedAndHelp() {
        #expect(PathemCLI.parse(["src"]) == .act(verb: nil, path: "src", printOnly: false))
        #expect(
            PathemCLI.parse(["--print", "src"]) == .act(verb: nil, path: "src", printOnly: true))
        #expect(PathemCLI.parse(["changed"]) == .changed(directory: nil, printOnly: false))
        #expect(
            PathemCLI.parse(["changed", "d", "--print"])
                == .changed(directory: "d", printOnly: true))
        #expect(PathemCLI.parse(["--help"]) == .help)
        #expect(PathemCLI.parse(["open", "--help"]) == .help)
    }

    @Test func invalidUsageIsNil() {
        #expect(PathemCLI.parse([]) == nil)
        #expect(PathemCLI.parse(["--print"]) == nil)
        #expect(PathemCLI.parse(["open"]) == nil)
        #expect(PathemCLI.parse(["open", "a", "b"]) == nil)
        #expect(PathemCLI.parse(["a", "b"]) == nil)
        #expect(PathemCLI.parse(["changed", "a", "b"]) == nil)
        #expect(PathemCLI.parse(["--bogus", "a"]) == nil)
    }

    @Test func automaticVerb() {
        #expect(PathemCLI.automaticVerb(isDirectory: true) == .open)
        #expect(PathemCLI.automaticVerb(isDirectory: false) == .reveal)
    }

    @Test func resolvesRelativePaths() {
        #expect(PathemCLI.resolve("a/../b.txt", against: "/tmp/x") == "/tmp/x/b.txt")
        #expect(PathemCLI.resolve("/etc/hosts", against: "/tmp/x") == "/etc/hosts")
    }

    @Test func parsesPorcelainWithRenamesAndSpaces() {
        let raw = " M src/a.swift\0?? new file.txt\0R  new.txt\0old.txt\0 D gone.txt\0A  é.txt\0"
        let paths = PathemCLI.parsePorcelainZ(Data(raw.utf8))
        #expect(paths == ["src/a.swift", "new file.txt", "new.txt", "gone.txt", "é.txt"])
        #expect(PathemCLI.parsePorcelainZ(Data()) == [])
    }
}
