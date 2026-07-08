import Foundation
import Testing

@testable import PathemEngine

@Suite struct ExternalCommandTests {
    private let dir = URL(fileURLWithPath: "/tmp/pathem work")
    private var files: [URL] {
        [dir.appendingPathComponent("a b.txt"), dir.appendingPathComponent("c.txt")]
    }

    @Test func expandsPlaceholdersShellQuoted() {
        let out = ExternalCommandRunner.expand("tool %F in %D", files: files, directory: dir)
        #expect(out == "tool '/tmp/pathem work/a b.txt' '/tmp/pathem work/c.txt' in '/tmp/pathem work'")
    }

    @Test func expandsNamesAndParent() {
        #expect(ExternalCommandRunner.expand("%N", files: files, directory: dir) == "'a b.txt' 'c.txt'")
        #expect(ExternalCommandRunner.expand("%P", files: files, directory: dir) == "'/tmp/pathem work'")
    }

    @Test func doublePercentIsLiteral() {
        #expect(ExternalCommandRunner.expand("resize 50%% keep %%F", files: files, directory: dir)
            == "resize 50% keep %F")
    }

    @Test func quoteEscapesEmbeddedSingleQuote() {
        #expect(ExternalCommandRunner.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func runsAndCapturesOutputAndExitCode() {
        let echo = ExternalCommand(id: "1", name: "echo", command: "echo hi %N")
        let out = ExternalCommandRunner.run(echo, files: files, directory: URL(fileURLWithPath: "/tmp"))
        #expect(out.succeeded)
        // The shell consumes the quotes we added, so echo sees "a b.txt" as one argument.
        #expect(out.text.trimmingCharacters(in: .whitespacesAndNewlines) == "hi a b.txt c.txt")

        let fail = ExternalCommand(id: "2", name: "false", command: "exit 3")
        #expect(ExternalCommandRunner.run(fail, files: [], directory: URL(fileURLWithPath: "/tmp")).exitCode == 3)
    }
}
